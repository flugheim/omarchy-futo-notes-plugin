/**
 * Futo Notes Crypto Module
 * Implements the encryption/decryption as per Futo Notes specification
 * Based on: https://notes.futo.tech/docs/encryption/
 */

// Crypto helper using Quickshell's built-in crypto
var Crypto = {
    // PBKDF2-HMAC-SHA256
    pbkdf2: function(password, salt, iterations, keyLength) {
        return Quickshell.Crypto.pbkdf2("sha256", password, salt, iterations, keyLength);
    },

    // HKDF-SHA256
    hkdf: function(ikm, salt, info, length) {
        return Quickshell.Crypto.hkdf("sha256", ikm, salt, info, length);
    },

    // AES-GCM decrypt
    aesGcmDecrypt: function(key, nonce, ciphertext, aad) {
        return Quickshell.Crypto.aesGcmDecrypt(key, nonce, ciphertext, aad);
    },

    // AES-GCM encrypt
    aesGcmEncrypt: function(key, nonce, plaintext, aad) {
        return Quickshell.Crypto.aesGcmEncrypt(key, nonce, plaintext, aad);
    },

    // Generate random bytes
    randomBytes: function(length) {
        return Quickshell.Crypto.randomBytes(length);
    },

    // Base64 encode/decode
    base64Encode: function(bytes) {
        return Quickshell.Crypto.base64Encode(bytes);
    },

    base64Decode: function(b64) {
        return Quickshell.Crypto.base64Decode(b64);
    },

    // Convert string to Uint8Array
    stringToBytes: function(str) {
        return new TextEncoder().encode(str);
    },

    // Convert Uint8Array to string
    bytesToString: function(bytes) {
        return new TextDecoder().decode(bytes);
    }
};

/**
 * Key Hierarchy (from Futo Notes docs):
 *
 * 1. Password + Salt + PBKDF2 -> Key Encryption Key (KEK)
 * 2. KEK + encrypted_vault_key -> Vault Key (32 bytes)
 * 3. Vault Key + HKDF(info="futo-notes/object/" + objectId) -> Object Key
 * 4. Object Key + AES-GCM -> Decrypted blob content
 */

// Parse vault key material from server
function parseVaultKeyMaterial(keyMaterial, password) {
    // keyMaterial has: key_salt, key_kdf, encrypted_vault_key, key_updated_at
    var keySalt = Crypto.base64Decode(keyMaterial.key_salt);
    var kdf = keyMaterial.key_kdf; // { kdf: "pbkdf2-sha256", iterations: 100000, hash: "SHA-256" }
    var encryptedVaultKey = Crypto.base64Decode(keyMaterial.encrypted_vault_key);

    // Derive KEK from password
    var kek = Crypto.pbkdf2(password, keySalt, kdf.iterations, 32);

    // Decrypt vault key
    // Format: nonce (12 bytes) || ciphertext || tag (16 bytes)
    var nonce = encryptedVaultKey.slice(0, 12);
    var ciphertextAndTag = encryptedVaultKey.slice(12);
    var ciphertext = ciphertextAndTag.slice(0, -16);
    var tag = ciphertextAndTag.slice(-16);

    // Combine ciphertext + tag for AES-GCM
    var encryptedData = new Uint8Array(ciphertext.length + tag.length);
    encryptedData.set(ciphertext);
    encryptedData.set(tag, ciphertext.length);

    var vaultKey = Crypto.aesGcmDecrypt(kek, nonce, encryptedData, null);

    return vaultKey; // 32-byte vault key
}

// Derive per-object key from vault key
function deriveObjectKey(vaultKey, objectId) {
    var info = Crypto.stringToBytes("futo-notes/object/" + objectId);
    return Crypto.hkdf(vaultKey, null, info, 32);
}

// Decrypt a blob using the object key
function decryptBlob(blobData, objectKey) {
    // Blob format: nonce (12 bytes) || ciphertext || tag (16 bytes)
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

// Parse note content from decrypted blob
function parseNoteContent(decryptedBytes) {
    var content = Crypto.bytesToString(decryptedBytes);

    // Parse frontmatter if present
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
        // Use first non-empty line as title
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

// Full decryption pipeline
function decryptNote(blobData, vaultKey, objectId) {
    var objectKey = deriveObjectKey(vaultKey, objectId);
    var decrypted = decryptBlob(blobData, objectKey);
    return parseNoteContent(decrypted);
}

// Export for QML
var FutoCrypto = {
    parseVaultKeyMaterial: parseVaultKeyMaterial,
    deriveObjectKey: deriveObjectKey,
    decryptBlob: decryptBlob,
    parseNoteContent: parseNoteContent,
    decryptNote: decryptNote,
    Crypto: Crypto
};