/**
 * Futo Notes API Model
 * Handles communication with self-hosted Futo Notes sync server
 * Includes E2EE decryption (PBKDF2, HKDF, AES-GCM)
 */

// ---------------------------------------------------------------------------
// Crypto helpers
// ---------------------------------------------------------------------------

var Crypto = {
    pbkdf2: function(password, salt, iterations, keyLength) {
        return Quickshell.Crypto.pbkdf2("sha256", password, salt, iterations, keyLength);
    },

    hkdf: function(ikm, salt, info, length) {
        return Quickshell.Crypto.hkdf("sha256", ikm, salt, info, length);
    },

    aesGcmDecrypt: function(key, nonce, ciphertext, aad) {
        return Quickshell.Crypto.aesGcmDecrypt(key, nonce, ciphertext, aad);
    },

    aesGcmEncrypt: function(key, nonce, plaintext, aad) {
        return Quickshell.Crypto.aesGcmEncrypt(key, nonce, plaintext, aad);
    },

    randomBytes: function(length) {
        return Quickshell.Crypto.randomBytes(length);
    },

    base64Encode: function(bytes) {
        return Quickshell.Crypto.base64Encode(bytes);
    },

    base64Decode: function(b64) {
        return Quickshell.Crypto.base64Decode(b64);
    },

    stringToBytes: function(str) {
        return new TextEncoder().encode(str);
    },

    bytesToString: function(bytes) {
        return new TextDecoder().decode(bytes);
    }
};

// ---------------------------------------------------------------------------
// E2EE key hierarchy
// ---------------------------------------------------------------------------
//
// 1. Password + Salt + PBKDF2  -> Key Encryption Key (KEK)
// 2. KEK + encrypted_vault_key -> Vault Key (32 bytes)
// 3. Vault Key + HKDF(info="futo-notes/object/" + objectId) -> Object Key
// 4. Object Key + AES-GCM      -> Decrypted blob content
// ---------------------------------------------------------------------------

function parseVaultKeyMaterial(keyMaterial, password) {
    var keySalt = Crypto.base64Decode(keyMaterial.key_salt);
    var kdf = keyMaterial.key_kdf;
    var encryptedVaultKey = Crypto.base64Decode(keyMaterial.encrypted_vault_key);

    // Derive KEK from password
    var kek = Crypto.pbkdf2(password, keySalt, kdf.iterations, 32);

    // Decrypt vault key: nonce (12 bytes) || ciphertext || tag (16 bytes)
    var nonce = encryptedVaultKey.slice(0, 12);
    var ciphertextAndTag = encryptedVaultKey.slice(12);
    var ciphertext = ciphertextAndTag.slice(0, -16);
    var tag = ciphertextAndTag.slice(-16);

    var encryptedData = new Uint8Array(ciphertext.length + tag.length);
    encryptedData.set(ciphertext);
    encryptedData.set(tag, ciphertext.length);

    return Crypto.aesGcmDecrypt(kek, nonce, encryptedData, null);
}

function deriveObjectKey(vaultKey, objectId) {
    var info = Crypto.stringToBytes("futo-notes/object/" + objectId);
    return Crypto.hkdf(vaultKey, null, info, 32);
}

function decryptBlob(blobData, objectKey) {
    if (blobData.length < 12 + 16) {
        throw new Error("Blob too small");
    }

    var nonce = blobData.slice(0, 12);
    var ciphertextAndTag = blobData.slice(12);
    var ciphertext = ciphertextAndTag.slice(0, -16);
    var tag = ciphertextAndTag.slice(-16);

    var encryptedData = new Uint8Array(ciphertext.length + tag.length);
    encryptedData.set(ciphertext);
    encryptedData.set(tag, ciphertext.length);

    return Crypto.aesGcmDecrypt(objectKey, nonce, encryptedData, null);
}

function parseNoteContent(decryptedBytes) {
    var content = Crypto.bytesToString(decryptedBytes);

    var title = "Untitled";
    var tags = [];
    var folder = "";
    var body = content;

    var fmMatch = content.match(/^---\n([\s\S]*?)\n---/);
    if (fmMatch) {
        var fm = fmMatch[1];
        var titleMatch = fm.match(/title:\s*(.+)/);
        if (titleMatch) title = titleMatch[1].trim().replace(/^["']|["']$/g, '');
        var tagsMatch = fm.match(/tags:\s*\[([^\]]*)\]/);
        if (tagsMatch) {
            var tagsStr = tagsMatch[1].trim();
            if (tagsStr) {
                tags = tagsStr.split(",").map(function(t) { return t.trim().replace(/^["']|["']$/g, ''); });
            }
        }
        var folderMatch = fm.match(/folder:\s*(.+)/);
        if (folderMatch) folder = folderMatch[1].trim().replace(/^["']|["']$/g, '');
        body = content.substring(fmMatch[0].length).trimStart();
    } else {
        var lines = content.split("\n");
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim();
            if (line && !line.startsWith("#")) {
                title = line.substring(0, 80);
                break;
            } else if (line.startsWith("#")) {
                title = line.replace(/^#+\s*/, "").substring(0, 80);
                break;
            }
        }
    }

    return {
        title: title,
        body: body,
        tags: tags,
        folder: folder
    };
}

function decryptNote(blobData, vaultKey, objectId) {
    var objectKey = deriveObjectKey(vaultKey, objectId);
    var decrypted = decryptBlob(blobData, objectKey);
    return parseNoteContent(decrypted);
}

// ---------------------------------------------------------------------------
// API client for Futo Notes sync server
// ---------------------------------------------------------------------------

var FutoNotesAPI = {
    serverUrl: "",
    token: "",
    vaultKey: null,
    collectionId: "",

    init: function(settings) {
        this.serverUrl = settings.serverUrl || "";
        this.token = settings.token || "";
    },

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

    downloadBlobs: function(blobKeys) {
        if (blobKeys.length === 0) return {};

        var url = this.serverUrl + "/api/blobs/batch";
        var result = Quickshell.Http.post(url, JSON.stringify({ keys: blobKeys }), {
            "Authorization": "Bearer " + this.token,
            "Content-Type": "application/json"
        }, "arraybuffer");

        var blobs = {};
        if (result.status === 200) {
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

                if (status === 0 && offset + blobLen <= data.length) {
                    blobs[key] = data.slice(offset, offset + blobLen);
                }
                offset += blobLen;
            }
        }
        return blobs;
    },

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

        try {
            this.vaultKey = parseVaultKeyMaterial(keyMaterial.key, password);
        } catch (e) {
            return { success: false, error: "Failed to decrypt vault key. Wrong password?" };
        }

        var objects = this.pullNotes(0);

        var blobKeys = objects
            .filter(function(o) { return !o.deleted && o.blob_key; })
            .map(function(o) { return o.blob_key; });

        var blobs = this.downloadBlobs(blobKeys);

        var notes = [];
        for (var i = 0; i < objects.length; i++) {
            var obj = objects[i];
            if (obj.deleted) continue;

            var blob = obj.blob_key ? blobs[obj.blob_key] : null;
            if (!blob) continue;

            try {
                var decrypted = decryptNote(blob, this.vaultKey, obj.id);
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
                console.log("Failed to decrypt note " + obj.id + ": " + e);
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

// ---------------------------------------------------------------------------
// Settings management
// ---------------------------------------------------------------------------

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
                console.log("Failed to load Futo Notes settings: " + e);
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

// ---------------------------------------------------------------------------
// Note model for UI
// ---------------------------------------------------------------------------

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
    NoteModel: NoteModel
};