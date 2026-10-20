//
//  EncryptedBackupService.swift
//  ExcalidrawZ
//
//  Created by Codex on 2026/05/31.
//

import CryptoKit
import Foundation
import Security

enum EncryptedBackupError: LocalizedError, Equatable {
    case invalidEnvelope
    case unsupportedVersion(Int)
    case unsupportedAlgorithm(String)
    case missingKey
    case invalidKey
    case keyMismatch
    case keychainError(OSStatus)
    case encryptionFailed
    case decryptionFailed

    var errorDescription: String? {
        switch self {
            case .invalidEnvelope:
                String(localizable: .encryptedBackupErrorInvalidEnvelope)
            case .unsupportedVersion:
                String(localizable: .encryptedBackupErrorUnsupportedVersion)
            case .unsupportedAlgorithm:
                String(localizable: .encryptedBackupErrorUnsupportedAlgorithm)
            case .missingKey:
                String(localizable: .encryptedBackupErrorMissingKey)
            case .invalidKey:
                String(localizable: .encryptedBackupErrorInvalidKey)
            case .keyMismatch:
                String(localizable: .encryptedBackupErrorKeyMismatch)
            case .keychainError:
                String(localizable: .encryptedBackupErrorKeychain)
            case .encryptionFailed:
                String(localizable: .encryptedBackupErrorEncryptionFailed)
            case .decryptionFailed:
                String(localizable: .encryptedBackupErrorDecryptionFailed)
        }
    }
}

struct EncryptedBackupEnvelope: Codable, Equatable, Sendable {
    static let magicValue = "EDZBAK"
    static let currentVersion = 1
    static let algorithmValue = "AES-GCM-256"

    var magic: String
    var version: Int
    var algorithm: String
    var keyID: String?
    var payload: EncryptedContentEnvelope.SealedData
}

enum EncryptedBackupService {
    private static let associatedData = Data("ExcalidrawZ internal backup encrypted file v1".utf8)

    static func encrypt(_ plaintext: Data) throws -> Data {
        do {
            let keyData = try BackupEncryptionKeyStore.loadOrCreateKeyData()
            let key = SymmetricKey(data: keyData)
            let sealedBox = try AES.GCM.seal(
                plaintext,
                using: key,
                authenticating: associatedData
            )
            let envelope = EncryptedBackupEnvelope(
                magic: EncryptedBackupEnvelope.magicValue,
                version: EncryptedBackupEnvelope.currentVersion,
                algorithm: EncryptedBackupEnvelope.algorithmValue,
                keyID: keyIdentifier(for: keyData),
                payload: .init(sealedBox: sealedBox)
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(envelope)
        } catch let error as EncryptedBackupError {
            throw error
        } catch {
            throw EncryptedBackupError.encryptionFailed
        }
    }

    static func decrypt(_ encryptedData: Data) throws -> Data {
        let envelope = try decodeEnvelope(encryptedData)
        try validate(envelope)

        do {
            let keyData = try BackupEncryptionKeyStore.loadExistingKeyData()
            if let keyID = envelope.keyID,
               keyID != keyIdentifier(for: keyData) {
                throw EncryptedBackupError.keyMismatch
            }
            return try AES.GCM.open(
                envelope.payload.sealedBox(),
                using: SymmetricKey(data: keyData),
                authenticating: associatedData
            )
        } catch let error as EncryptedBackupError {
            throw error
        } catch {
            throw EncryptedBackupError.decryptionFailed
        }
    }

    static func decryptIfNeeded(_ data: Data) throws -> Data {
        isEncryptedEnvelope(data) ? try decrypt(data) : data
    }

    static func decodeEnvelope(_ data: Data) throws -> EncryptedBackupEnvelope {
        do {
            return try JSONDecoder().decode(EncryptedBackupEnvelope.self, from: data)
        } catch {
            throw EncryptedBackupError.invalidEnvelope
        }
    }

    static func isEncryptedEnvelope(_ data: Data) -> Bool {
        guard data.range(of: Data(EncryptedBackupEnvelope.magicValue.utf8)) != nil,
              let envelope = try? decodeEnvelope(data) else {
            return false
        }
        return envelope.magic == EncryptedBackupEnvelope.magicValue
    }

    private static func validate(_ envelope: EncryptedBackupEnvelope) throws {
        guard envelope.magic == EncryptedBackupEnvelope.magicValue else {
            throw EncryptedBackupError.invalidEnvelope
        }
        guard envelope.version == EncryptedBackupEnvelope.currentVersion else {
            throw EncryptedBackupError.unsupportedVersion(envelope.version)
        }
        guard envelope.algorithm == EncryptedBackupEnvelope.algorithmValue else {
            throw EncryptedBackupError.unsupportedAlgorithm(envelope.algorithm)
        }
    }

    private static func keyIdentifier(for keyData: Data) -> String {
        Data(SHA256.hash(data: keyData).prefix(16)).base64EncodedString()
    }
}

private enum BackupEncryptionKeyStore {
    private static let byteCount = 32
    private static let account = "InternalBackupMasterKey"
    private static let service = "\(Bundle.main.bundleIdentifier ?? "com.chocoford.ExcalidrawZ").backup-encryption"

    /// The key never changes once created. A backup encrypts every file, and
    /// each Keychain read can show an access prompt after an unsigned rebuild;
    /// read it once per launch.
    private static let cacheLock = NSLock()
    private static var cachedKeyData: Data?

    static func loadOrCreateKeyData() throws -> Data {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cachedKeyData { return cachedKeyData }
        if let existingKeyData = try loadKeyDataIfPresent() {
            cachedKeyData = try validatedKeyData(existingKeyData)
            return existingKeyData
        }

        let keyData = try RecoveryKeyService.randomSalt(byteCount: byteCount)
        try saveKeyData(keyData)
        cachedKeyData = keyData
        return keyData
    }

    static func loadExistingKeyData() throws -> Data {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cachedKeyData { return cachedKeyData }
        guard let existingKeyData = try loadKeyDataIfPresent() else {
            throw EncryptedBackupError.missingKey
        }
        cachedKeyData = try validatedKeyData(existingKeyData)
        return existingKeyData
    }

    private static func validatedKeyData(_ keyData: Data) throws -> Data {
        guard keyData.count == byteCount else {
            throw EncryptedBackupError.invalidKey
        }
        return keyData
    }

    private static func loadKeyDataIfPresent() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
            case errSecSuccess:
                guard let data = item as? Data else {
                    throw EncryptedBackupError.invalidKey
                }
                return data
            case errSecItemNotFound:
                return nil
            default:
                throw EncryptedBackupError.keychainError(status)
        }
    }

    private static func saveKeyData(_ keyData: Data) throws {
        guard keyData.count == byteCount else {
            throw EncryptedBackupError.invalidKey
        }

        var attributes = baseQuery()
        attributes[kSecValueData as String] = keyData
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            var updatedAttributes: [String: Any] = [:]
            updatedAttributes[kSecValueData as String] = keyData
            updatedAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, updatedAttributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw EncryptedBackupError.keychainError(updateStatus)
            }
            return
        }

        guard status == errSecSuccess else {
            throw EncryptedBackupError.keychainError(status)
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
