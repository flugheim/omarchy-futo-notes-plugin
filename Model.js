/**
 * Futo Notes API Model
 * Handles communication with self-hosted Futo Notes sync server
 * Uses FutoCrypto for E2EE decryption
 */

import "FutoCrypto.js" as FutoCrypto

// API client for Futo Notes sync server
var FutoNotesAPI = {
    serverUrl: "",
    token: "",
    vaultKey: null,
    collectionId: "",

    // Initialize from settings
    init: function(settings) {
        this.serverUrl = settings.serverUrl || "";
        this.token = settings.token || "";
    },

    // Login with password
    login: function(password) {
        var url = this.serverUrl + "/api/auth/password/login";
        var body = JSON.stringify({ password: password });

        var result = Quickshell.Http.post(url, body, {
            "Content-Type": "application/json"
        });

        if (result.status === 200) {
            var data = JSON.parse(result.body);
            this.token = data.token;
            return { success: true, user: data.user };
        } else {
            var error = "Login failed";
            try {
                var errData = JSON.parse(result.body);
                error = errData.error || error;
            } catch (e) {}
            return { success: false, error: error };
        }
    },

    // Get current user (validate token)
    getUser: function() {
        var url = this.serverUrl + "/api/auth";
        var result = Quickshell.Http.get(url, {
            "Authorization": "Bearer " + this.token
        });

        if (result.status === 200) {
            return JSON.parse(result.body);
        }
        return null;
    },

    // Get or create collection (vault)
    getCollection: function() {
        var url = this.serverUrl + "/api/collections";
        var result = Quickshell.Http.post(url, "", {
            "Authorization": "Bearer " + this.token,
            "Content-Type": "application/json"
        });

        if (result.status === 200 || result.status === 201) {
            var data = JSON.parse(result.body);
            this.collectionId = data.collection.id;
            return data.collection;
        }
        return null;
    },

    // Get vault key material
    getVaultKeyMaterial: function() {
        if (!this.collectionId) return null;

        var url = this.serverUrl + "/api/collections/" + this.collectionId + "/key";
        var result = Quickshell.Http.get(url, {
            "Authorization": "Bearer " + this.token
        });

        if (result.status === 200) {
            return JSON.parse(result.body);
        }
        return { key: null };
    },

    // Pull notes (objects) from server
    pullNotes: function(sinceVersion) {
        if (!this.collectionId) return [];

        var url = this.serverUrl + "/api/collections/" + this.collectionId + "/objects";
        if (sinceVersion !== undefined) {
            url += "?sinceVersion=" + sinceVersion;
        }

        var result = Quickshell.Http.get(url, {
            "Authorization": "Bearer " + this.token
        });

        if (result.status === 200) {
            var data = JSON.parse(result.body);
            return data.objects || [];
        }
        return [];
    },

    // Download blobs in batch
    downloadBlobs: function(blobKeys) {
        if (blobKeys.length === 0) return {};

        var url = this.serverUrl + "/api/blobs/batch";
        var result = Quickshell.Http.post(url, JSON.stringify({ keys: blobKeys }), {
            "Authorization": "Bearer " + this.token,
            "Content-Type": "application/json"
        }, "arraybuffer");

        var blobs = {};
        if (result.status === 200) {
            // Parse binary response format:
            // [u16 key length][key, UTF-8][u8 status][u32 blob length][blob]
            var data = new Uint8Array(result.body);
            var offset = 0;
            var decoder = new TextDecoder();

            for (var i = 0; i < blobKeys.length && offset < data.length; i++) {
                if (offset + 2 > data.length) break;
                var keyLen = (data[offset] << 8) | data[offset + 1];
                offset += 2;

                if (offset + keyLen > data.length) break;
                var key = decoder.decode(data.slice(offset, offset + keyLen));
                offset += keyLen;

                if (offset >= data.length) break;
                var status = data[offset++];

                if (offset + 4 > data.length) break;
                var blobLen = (data[offset] << 24) | (data[offset + 1] << 16) | (data[offset + 2] << 8) | data[offset + 3];
                offset += 4;

                if (status === 0 && offset + blobLen <= data.length) { // found
                    blobs[key] = data.slice(offset, offset + blobLen);
                }
                offset += blobLen;
            }
        }
        return blobs;
    },

    // Full sync: login, get collection, get key material, pull notes, decrypt
    fullSync: function(password) {
        var loginResult = this.login(password);
        if (!loginResult.success) {
            return { success: false, error: loginResult.error };
        }

        var collection = this.getCollection();
        if (!collection) {
            return { success: false, error: "Failed to get collection" };
        }

        var keyMaterial = this.getVaultKeyMaterial();
        if (!keyMaterial || !keyMaterial.key) {
            return { success: false, error: "No vault key material found. Has the vault been initialized on another device?" };
        }

        // Derive vault key from password
        try {
            this.vaultKey = FutoCrypto.parseVaultKeyMaterial(keyMaterial.key, password);
        } catch (e) {
            return { success: false, error: "Failed to decrypt vault key. Wrong password?" };
        }

        // Pull notes
        var objects = this.pullNotes(0);

        // Download blobs
        var blobKeys = objects
            .filter(function(o) { return !o.deleted && o.blob_key; })
            .map(function(o) { return o.blob_key; });

        var blobs = this.downloadBlobs(blobKeys);

        // Decrypt notes
        var notes = [];
        for (var i = 0; i < objects.length; i++) {
            var obj = objects[i];
            if (obj.deleted) continue;

            var blob = obj.blob_key ? blobs[obj.blob_key] : null;
            if (!blob) continue;

            try {
                var decrypted = FutoCrypto.decryptNote(blob, this.vaultKey, obj.id);
                notes.push({
                    id: obj.id,
                    title: decrypted.title,
                    content: decrypted.body,
                    tags: decrypted.tags,
                    folder: decrypted.folder,
                    createdAt: obj.created_at,
                    updatedAt: obj.updated_at,
                    version: obj.version
                });
            } catch (e) {
                console.log("Failed to decrypt note " + obj.id + ":", e);
                // Add placeholder for failed decryption
                notes.push({
                    id: obj.id,
                    title: "[Encrypted - failed to decrypt]",
                    content: "Could not decrypt this note. Check password.",
                    tags: [],
                    folder: "",
                    createdAt: obj.created_at,
                    updatedAt: obj.updated_at,
                    version: obj.version
                });
            }
        }

        return {
            success: true,
            notes: notes,
            collectionVersion: collection.current_version
        };
    }
};

// Settings management
var Settings = {
    getPath: function() {
        return Quickshell.env("HOME") + "/.local/state/omarchy/settings/futo-notes.json";
    },

    load: function() {
        var path = this.getPath();
        var content = Quickshell.FileSystem.readFile(path);
        if (content) {
            try {
                return JSON.parse(content);
            } catch (e) {
                console.log("Failed to load Futo Notes settings:", e);
            }
        }
        return this.defaults();
    },

    save: function(settings) {
        var path = this.getPath();
        var dir = path.substring(0, path.lastIndexOf("/"));
        Quickshell.FileSystem.mkpath(dir);
        Quickshell.FileSystem.writeFile(path, JSON.stringify(settings, null, 2));
    },

    defaults: function() {
        return {
            serverUrl: "",
            token: "",
            refreshMinutes: 15
        };
    }
};

// Note model for UI
var NoteModel = {
    notes: [],
    lastSync: null,
    syncing: false,
    error: null,

    loadNotes: function(api, password) {
        this.syncing = true;
        this.error = null;

        var result = api.fullSync(password);
        if (result.success) {
            this.notes = result.notes;
            this.lastSync = new Date();
            this.syncing = false;
            return result.notes;
        } else {
            this.error = result.error;
            this.syncing = false;
            return [];
        }
    }
};

// Export for QML
var Model = {
    FutoNotesAPI: FutoNotesAPI,
    Settings: Settings,
    NoteModel: NoteModel,
    FutoCrypto: FutoCrypto
};