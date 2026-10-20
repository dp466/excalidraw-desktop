//
//  EncryptedContentEnvelope.swift
//  ExcalidrawZ
//
//  Created by Codex on 2026/05/27.
//

import CryptoKit
import Foundation

enum EncryptedContentError: LocalizedError, Equatable {
    case contentLocked(contentType: String, contentID: String)
    case contentIdentityMismatch(expectedType: String, expectedID: String, actualType: String, actualID: String)
    case invalidEnvelope
    case unsupportedVersion(Int)
    case unsupportedAlgorithm(String)
    case invalidRecoveryMetadata
    case invalidWrappedFileKey
    case recoveryVerificationFailed
    case encryptionFailed
    case decryptionFailed

    var errorDescription: String? {
        switch self {
            case .contentLocked:
                String(localizable: .lockedContentErrorFileLocked)
            case .contentIdentityMismatch:
                String(localizable: .lockedContentErrorIdentityMismatch)
            case .invalidEnvelope:
                String(localizable: .lockedContentErrorInvalidEnvelope)
            case .unsupportedVersion:
                String(localizable: .lockedContentErrorUnsupportedVersion)
            case .unsupportedAlgorithm:
                String(localizable: .lockedContentErrorUnsupportedAlgorithm)
            case .invalidRecoveryMetadata:
                String(localizable: .lockedContentErrorInvalidRecoveryMetadata)
            case .invalidWrappedFileKey:
                String(localizable: .lockedContentErrorInvalidWrappedFileKey)
            case .recoveryVerificationFailed:
                String(localizable: .lockedContentErrorRecoveryVerificationFailed)
            case .encryptionFailed:
                String(localizable: .lockedContentErrorEncryptionFailed)
            case .decryptionFailed:
                String(localizable: .lockedContentErrorDecryptionFailed)
        }
    }

    var recoverySuggestion: String? {
        switch self {
            case .contentLocked:
                String(localizable: .lockedContentSuggestionUnlock)
            case .contentIdentityMismatch:
                String(localizable: .lockedContentSuggestionOpenOriginal)
            case .invalidEnvelope, .unsupportedVersion, .unsupportedAlgorithm,
                    .invalidRecoveryMetadata, .invalidWrappedFileKey:
                String(localizable: .lockedContentSuggestionUseBackup)
            case .recoveryVerificationFailed, .encryptionFailed:
                String(localizable: .lockedContentSuggestionTryAgainBeforeClosing)
            case .decryptionFailed:
                String(localizable: .lockedContentSuggestionCheckRecoveryKey)
        }
    }
}

extension EncryptedContentError {
    var isContentLocked: Bool {
        switch self {
            case .contentLocked:
                return true
            default:
                return false
        }
    }

    var allowsPermanentDeleteFallback: Bool {
        switch self {
            case .contentLocked, .encryptionFailed, .recoveryVerificationFailed:
                return false
            case .contentIdentityMismatch,
                    .invalidEnvelope,
                    .unsupportedVersion,
                    .unsupportedAlgorithm,
                    .invalidRecoveryMetadata,
                    .invalidWrappedFileKey:
                return true
            case .decryptionFailed:
                return false
        }
    }
}

struct EncryptedContentEnvelope: Codable, Equatable, Sendable {
    static let magicValue = "EDZENC"
    static let currentVersion = 1
    static let contentAlgorithm = "AES-GCM-256"
    static let recoveryKDFAlgorithm = "HKDF-SHA256"

    var magic: String
    var version: Int
    var contentType: String
    var contentID: String
    var algorithm: String
    var recoveryKeyDerivation: KeyDerivation
    var recoveryWrappedFileKey: SealedData
    var localWrappedFileKey: SealedData?
    var payload: SealedData

    struct KeyDerivation: Codable, Equatable, Sendable {
        var algorithm: String
        var salt: String
        var outputBytes: Int

        init(algorithm: String, salt: Data, outputBytes: Int) {
            self.algorithm = algorithm
            self.salt = salt.base64EncodedString()
            self.outputBytes = outputBytes
        }

        func saltData() throws -> Data {
            guard let data = Data(base64Encoded: salt) else {
                throw EncryptedContentError.invalidRecoveryMetadata
            }
            return data
        }
    }

    struct SealedData: Codable, Equatable, Sendable {
        var nonce: String
        var ciphertext: String
        var tag: String

        init(sealedBox: AES.GCM.SealedBox) {
            self.nonce = sealedBox.nonce.withUnsafeBytes { Data($0) }.base64EncodedString()
            self.ciphertext = sealedBox.ciphertext.base64EncodedString()
            self.tag = sealedBox.tag.base64EncodedString()
        }

        func sealedBox() throws -> AES.GCM.SealedBox {
            guard let nonceData = Data(base64Encoded: nonce),
                  let ciphertextData = Data(base64Encoded: ciphertext),
                  let tagData = Data(base64Encoded: tag) else {
                throw EncryptedContentError.invalidEnvelope
            }

            return try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonceData),
                ciphertext: ciphertextData,
                tag: tagData
            )
        }
    }
}

struct UnlockedContentKey: Equatable, Sendable {
    let contentType: String
    let contentID: String
    fileprivate let keyData: Data
}

enum EncryptedContentService {
    private static let fileKeyByteCount = 32

    static func encrypt(
        _ plaintext: Data,
        contentType: String,
        contentID: String,
        recoveryKey: RecoveryKey
    ) throws -> Data {
        let fileKeyData = try RecoveryKeyService.randomSalt(byteCount: fileKeyByteCount)
        let fileKey = SymmetricKey(data: fileKeyData)
        let recoverySalt = try RecoveryKeyService.randomSalt()
        let recoveryWrappingKey = RecoveryKeyService.deriveWrappingKey(
            from: recoveryKey,
            salt: recoverySalt
        )

        do {
            let recoveryWrappedFileKey = try seal(
                fileKeyData,
                using: recoveryWrappingKey,
                authenticating: additionalData(
                    kind: "recoveryWrappedFileKey",
                    contentType: contentType,
                    contentID: contentID
                )
            )

            let payload = try seal(
                plaintext,
                using: fileKey,
                authenticating: additionalData(
                    kind: "payload",
                    contentType: contentType,
                    contentID: contentID
                )
            )

            let envelope = EncryptedContentEnvelope(
                magic: EncryptedContentEnvelope.magicValue,
                version: EncryptedContentEnvelope.currentVersion,
                contentType: contentType,
                contentID: contentID,
                algorithm: EncryptedContentEnvelope.contentAlgorithm,
                recoveryKeyDerivation: .init(
                    algorithm: EncryptedContentEnvelope.recoveryKDFAlgorithm,
                    salt: recoverySalt,
                    outputBytes: fileKeyByteCount
                ),
                recoveryWrappedFileKey: recoveryWrappedFileKey,
                localWrappedFileKey: nil,
                payload: payload
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(envelope)
        } catch let error as EncryptedContentError {
            throw error
        } catch {
            throw EncryptedContentError.encryptionFailed
        }
    }

    static func encryptAndVerifyRecovery(
        _ plaintext: Data,
        contentType: String,
        contentID: String,
        recoveryKey: RecoveryKey
    ) throws -> Data {
        let encryptedData = try encrypt(
            plaintext,
            contentType: contentType,
            contentID: contentID,
            recoveryKey: recoveryKey
        )
        let recovered = try decrypt(encryptedData, recoveryKey: recoveryKey)
        guard recovered == plaintext else {
            throw EncryptedContentError.recoveryVerificationFailed
        }
        return encryptedData
    }

    static func decrypt(
        _ encryptedData: Data,
        recoveryKey: RecoveryKey
    ) throws -> Data {
        let unlockedKey = try unlockContentKey(encryptedData, recoveryKey: recoveryKey)
        return try decrypt(encryptedData, unlockedKey: unlockedKey)
    }

    static func unlockContentKey(
        _ encryptedData: Data,
        recoveryKey: RecoveryKey,
        expectedContentType: String? = nil,
        expectedContentID: String? = nil
    ) throws -> UnlockedContentKey {
        let envelope = try decodeEnvelope(encryptedData)
        try validate(envelope)
        try validateIdentity(
            envelope,
            expectedContentType: expectedContentType,
            expectedContentID: expectedContentID
        )

        do {
            let recoveryWrappingKey = RecoveryKeyService.deriveWrappingKey(
                from: recoveryKey,
                salt: try envelope.recoveryKeyDerivation.saltData(),
                outputByteCount: envelope.recoveryKeyDerivation.outputBytes
            )

            let fileKeyData = try open(
                envelope.recoveryWrappedFileKey,
                using: recoveryWrappingKey,
                authenticating: additionalData(
                    kind: "recoveryWrappedFileKey",
                    contentType: envelope.contentType,
                    contentID: envelope.contentID
                )
            )

            guard fileKeyData.count == fileKeyByteCount else {
                throw EncryptedContentError.invalidWrappedFileKey
            }

            return UnlockedContentKey(
                contentType: envelope.contentType,
                contentID: envelope.contentID,
                keyData: fileKeyData
            )
        } catch let error as EncryptedContentError {
            throw error
        } catch {
            throw EncryptedContentError.decryptionFailed
        }
    }

    static func decrypt(
        _ encryptedData: Data,
        unlockedKey: UnlockedContentKey,
        expectedContentType: String? = nil,
        expectedContentID: String? = nil
    ) throws -> Data {
        let envelope = try decodeEnvelope(encryptedData)
        try validate(envelope)
        try validateIdentity(
            envelope,
            expectedContentType: expectedContentType,
            expectedContentID: expectedContentID
        )
        try validateUnlockedKey(unlockedKey, matches: envelope)

        do {
            return try open(
                envelope.payload,
                using: SymmetricKey(data: unlockedKey.keyData),
                authenticating: additionalData(
                    kind: "payload",
                    contentType: envelope.contentType,
                    contentID: envelope.contentID
                )
            )
        } catch let error as EncryptedContentError {
            throw error
        } catch {
            throw EncryptedContentError.decryptionFailed
        }
    }

    static func resealPayload(
        _ plaintext: Data,
        existingEnvelopeData: Data,
        unlockedKey: UnlockedContentKey,
        expectedContentType: String? = nil,
        expectedContentID: String? = nil
    ) throws -> Data {
        var envelope = try decodeEnvelope(existingEnvelopeData)
        try validate(envelope)
        try validateIdentity(
            envelope,
            expectedContentType: expectedContentType,
            expectedContentID: expectedContentID
        )
        try validateUnlockedKey(unlockedKey, matches: envelope)

        do {
            envelope.payload = try seal(
                plaintext,
                using: SymmetricKey(data: unlockedKey.keyData),
                authenticating: additionalData(
                    kind: "payload",
                    contentType: envelope.contentType,
                    contentID: envelope.contentID
                )
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(envelope)
        } catch let error as EncryptedContentError {
            throw error
        } catch {
            throw EncryptedContentError.encryptionFailed
        }
    }

    static func rewrapRecoveryKey(
        existingEnvelopeData: Data,
        unlockedKey: UnlockedContentKey,
        newRecoveryKey: RecoveryKey,
        expectedContentType: String? = nil,
        expectedContentID: String? = nil
    ) throws -> Data {
        var envelope = try decodeEnvelope(existingEnvelopeData)
        try validate(envelope)
        try validateIdentity(
            envelope,
            expectedContentType: expectedContentType,
            expectedContentID: expectedContentID
        )
        try validateUnlockedKey(unlockedKey, matches: envelope)

        let recoverySalt = try RecoveryKeyService.randomSalt()
        let recoveryWrappingKey = RecoveryKeyService.deriveWrappingKey(
            from: newRecoveryKey,
            salt: recoverySalt
        )

        do {
            envelope.recoveryKeyDerivation = .init(
                algorithm: EncryptedContentEnvelope.recoveryKDFAlgorithm,
                salt: recoverySalt,
                outputBytes: fileKeyByteCount
            )
            envelope.recoveryWrappedFileKey = try seal(
                unlockedKey.keyData,
                using: recoveryWrappingKey,
                authenticating: additionalData(
                    kind: "recoveryWrappedFileKey",
                    contentType: envelope.contentType,
                    contentID: envelope.contentID
                )
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(envelope)
        } catch let error as EncryptedContentError {
            throw error
        } catch {
            throw EncryptedContentError.encryptionFailed
        }
    }

    static func decodeEnvelope(_ data: Data) throws -> EncryptedContentEnvelope {
        do {
            return try JSONDecoder().decode(EncryptedContentEnvelope.self, from: data)
        } catch {
            throw EncryptedContentError.invalidEnvelope
        }
    }

    static func isEncryptedEnvelope(_ data: Data) -> Bool {
        // Every save checks plain documents; skip the full JSON decode when the
        // magic marker cannot be present.
        guard data.range(of: Data(EncryptedContentEnvelope.magicValue.utf8)) != nil,
              let envelope = try? decodeEnvelope(data) else {
            return false
        }
        return envelope.magic == EncryptedContentEnvelope.magicValue
    }

    private static func validate(_ envelope: EncryptedContentEnvelope) throws {
        guard envelope.magic == EncryptedContentEnvelope.magicValue else {
            throw EncryptedContentError.invalidEnvelope
        }
        guard envelope.version == EncryptedContentEnvelope.currentVersion else {
            throw EncryptedContentError.unsupportedVersion(envelope.version)
        }
        guard envelope.algorithm == EncryptedContentEnvelope.contentAlgorithm else {
            throw EncryptedContentError.unsupportedAlgorithm(envelope.algorithm)
        }
        guard envelope.recoveryKeyDerivation.algorithm == EncryptedContentEnvelope.recoveryKDFAlgorithm,
              envelope.recoveryKeyDerivation.outputBytes == fileKeyByteCount else {
            throw EncryptedContentError.invalidRecoveryMetadata
        }
    }

    private static func validateIdentity(
        _ envelope: EncryptedContentEnvelope,
        expectedContentType: String?,
        expectedContentID: String?
    ) throws {
        if let expectedContentType,
           let expectedContentID,
           (envelope.contentType != expectedContentType || envelope.contentID != expectedContentID) {
            throw EncryptedContentError.contentIdentityMismatch(
                expectedType: expectedContentType,
                expectedID: expectedContentID,
                actualType: envelope.contentType,
                actualID: envelope.contentID
            )
        }
    }

    private static func validateUnlockedKey(
        _ unlockedKey: UnlockedContentKey,
        matches envelope: EncryptedContentEnvelope
    ) throws {
        guard unlockedKey.contentType == envelope.contentType,
              unlockedKey.contentID == envelope.contentID else {
            throw EncryptedContentError.contentIdentityMismatch(
                expectedType: envelope.contentType,
                expectedID: envelope.contentID,
                actualType: unlockedKey.contentType,
                actualID: unlockedKey.contentID
            )
        }
        guard unlockedKey.keyData.count == fileKeyByteCount else {
            throw EncryptedContentError.invalidWrappedFileKey
        }
    }

    private static func seal(
        _ data: Data,
        using key: SymmetricKey,
        authenticating additionalData: Data
    ) throws -> EncryptedContentEnvelope.SealedData {
        let sealedBox = try AES.GCM.seal(data, using: key, authenticating: additionalData)
        return EncryptedContentEnvelope.SealedData(sealedBox: sealedBox)
    }

    private static func open(
        _ sealedData: EncryptedContentEnvelope.SealedData,
        using key: SymmetricKey,
        authenticating additionalData: Data
    ) throws -> Data {
        try AES.GCM.open(sealedData.sealedBox(), using: key, authenticating: additionalData)
    }

    private static func additionalData(
        kind: String,
        contentType: String,
        contentID: String
    ) -> Data {
        Data(
            [
                EncryptedContentEnvelope.magicValue,
                String(EncryptedContentEnvelope.currentVersion),
                EncryptedContentEnvelope.contentAlgorithm,
                kind,
                contentType,
                contentID
            ].joined(separator: "|").utf8
        )
    }
}
