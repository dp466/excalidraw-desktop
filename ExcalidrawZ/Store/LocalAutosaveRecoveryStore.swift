//
//  LocalAutosaveRecoveryStore.swift
//  ExcalidrawZ
//
//  A bounded, local-only recovery copy for ordinary Excalidraw documents.
//

import CryptoKit
import Foundation
import Darwin

actor LocalAutosaveRecoveryStore {
    struct Retention: Sendable, Equatable {
        let maximumDocuments: Int
        let maximumBytes: Int64

        static let standard = Retention(maximumDocuments: 20, maximumBytes: 1_000_000_000)

        init(maximumDocuments: Int = 20, maximumBytes: Int64 = 1_000_000_000) {
            self.maximumDocuments = max(1, maximumDocuments)
            self.maximumBytes = max(0, maximumBytes)
        }
    }

    enum RecoveryError: Error, Equatable {
        case invalidDocumentID
        case invalidExcalidrawPayload
    }

    static let defaultDirectory: URL = {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("ExcalidrawDesktop", isDirectory: true)
            .appendingPathComponent("AutosaveRecovery", isDirectory: true)
    }()

    static let shared = LocalAutosaveRecoveryStore()

    private struct PreparedContent: Sendable {
        let data: Data
        let version: String
        let fingerprint: Data
    }

    private struct DocumentDirectory {
        let url: URL
        let modificationDate: Date
        let byteCount: Int64
    }

    private let directory: URL
    private let retention: Retention
    private let fileManager = FileManager.default
    /// Fingerprint of the current copy this store installed, by document directory.
    /// Lets an unchanged autosave skip JSON validation and re-reading the old copy.
    private var installedFingerprints: [String: Data] = [:]

    init(directory: URL = LocalAutosaveRecoveryStore.defaultDirectory, retention: Retention? = nil) {
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.retention = retention ?? .standard
    }

    /// Returns the directory containing only this store's recovery copies.
    func recoveryDirectory() throws -> URL {
        try createRecoveryDirectoryIfNeeded()
        return directory
    }

    /// Saves a validated, plaintext Excalidraw recovery copy. Protected documents are intentionally
    /// excluded by the caller before this store is used.
    func save(documentID: String, name: String, content: Data) async throws {
        let normalizedDocumentID = documentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDocumentID.isEmpty else {
            throw RecoveryError.invalidDocumentID
        }

        // This actor runs off MainActor. Do not suspend between validation and
        // installation: actor reentrancy could let an older snapshot replace a newer one.
        let directoryName = Self.documentDirectoryName(for: normalizedDocumentID)
        let fingerprint = Data(SHA256.hash(data: content))

        try createRecoveryDirectoryIfNeeded()
        let documentDirectory = directory
            .appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: documentDirectory, withIntermediateDirectories: true)

        let currentCopies = try ownCopyURLs(in: documentDirectory, prefix: "current-")
        if installedFingerprints[directoryName] == fingerprint, !currentCopies.isEmpty {
            // Same bytes as the copy this store last installed and validated.
            try prune(except: documentDirectory)
            return
        }
        let prepared = try Self.prepare(content: content, fingerprint: fingerprint)
        if let current = newestURL(in: currentCopies), try hasFingerprint(prepared.fingerprint, at: current) {
            installedFingerprints[directoryName] = prepared.fingerprint
            // Still prune after a logically successful autosave, but do not rewrite identical bytes.
            try prune(except: documentDirectory)
            return
        }

        let filenameStem = Self.safeFilenameStem(name: name, version: prepared.version)
        let destination = documentDirectory
            .appendingPathComponent("current-\(filenameStem).excalidraw", isDirectory: false)
        let incoming = documentDirectory
            .appendingPathComponent(".incoming-\(UUID().uuidString).excalidraw", isDirectory: false)

        // Atomic Data writes leave a complete incoming copy before any existing recovery copy moves.
        do {
            try prepared.data.write(to: incoming, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: incoming)
            throw error
        }

        if let current = newestURL(in: currentCopies) {
            let previous = documentDirectory.appendingPathComponent(
                "previous-\(Self.suffix(after: "current-", in: current.lastPathComponent))"
            )
            let previousIncoming = documentDirectory.appendingPathComponent(".incoming-\(UUID().uuidString).excalidraw")
            do {
                // Copy the old current before replacing it. Never move it away:
                // a crash at any point must leave a visible complete current copy.
                try fileManager.copyItem(at: current, to: previousIncoming)
                try atomicRename(previousIncoming, to: previous)
                try atomicRename(incoming, to: destination)
            } catch {
                try? fileManager.removeItem(at: incoming)
                try? fileManager.removeItem(at: previousIncoming)
                throw error
            }
            for old in try ownCopyURLs(in: documentDirectory, prefix: "previous-") where old.standardizedFileURL.path != previous.standardizedFileURL.path {
                try? fileManager.removeItem(at: old)
            }
        } else {
            do { try atomicRename(incoming, to: destination) }
            catch {
                try? fileManager.removeItem(at: incoming)
                throw error
            }
        }
        for old in currentCopies where old.standardizedFileURL.path != destination.standardizedFileURL.path {
            try? fileManager.removeItem(at: old)
        }

        installedFingerprints[directoryName] = prepared.fingerprint
        // Do not remove anything outside the store root, and only after the new copy installed.
        try? removeOwnCopies(in: documentDirectory, prefix: ".incoming-")
        try prune(except: documentDirectory)
    }

    private func atomicRename(_ source: URL, to destination: URL) throws {
        guard rename(source.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func createRecoveryDirectoryIfNeeded() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func hasFingerprint(_ expected: Data, at url: URL) throws -> Bool {
        let data = try Data(contentsOf: url)
        return Data(SHA256.hash(data: data)) == expected
    }

    private func ownCopyURLs(in documentDirectory: URL, prefix: String) throws -> [URL] {
        let contents = try fileManager.contentsOfDirectory(
            at: documentDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: []
        )
        return contents.filter { url in
            let filename = url.lastPathComponent
            return filename.hasPrefix(prefix) && filename.hasSuffix(".excalidraw")
        }
    }

    private func newestURL(in urls: [URL]) -> URL? {
        urls.max { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if leftDate == rightDate {
                return left.lastPathComponent < right.lastPathComponent
            }
            return leftDate < rightDate
        }
    }

    private func removeOwnCopies(in documentDirectory: URL, prefix: String) throws {
        for url in try ownCopyURLs(in: documentDirectory, prefix: prefix) {
            try fileManager.removeItem(at: url)
        }
    }

    private func prune(except activeDirectory: URL) throws {
        let documentDirectories = try storeDocumentDirectories()
        var totalBytes = documentDirectories.reduce(Int64(0)) { $0 + $1.byteCount }
        var remainingDocuments = documentDirectories.count

        for candidate in documentDirectories.sorted(by: { left, right in
            if left.modificationDate == right.modificationDate {
                return left.url.lastPathComponent < right.url.lastPathComponent
            }
            return left.modificationDate < right.modificationDate
        }) {
            guard candidate.url.standardizedFileURL.path != activeDirectory.standardizedFileURL.path else { continue }
            guard remainingDocuments > retention.maximumDocuments || totalBytes > retention.maximumBytes else { break }

            // A directory is removable only when every item is a file owned by this store.
            guard try isSafeToRemoveStoreDocumentDirectory(candidate.url) else { continue }
            try fileManager.removeItem(at: candidate.url)
            installedFingerprints[candidate.url.lastPathComponent] = nil
            remainingDocuments -= 1
            totalBytes -= candidate.byteCount
        }
    }

    private func storeDocumentDirectories() throws -> [DocumentDirectory] {
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        return try contents.compactMap { url in
            guard Self.isDocumentDirectoryName(url.lastPathComponent) else { return nil }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values.isDirectory == true else { return nil }
            let byteCount = try ownedByteCount(in: url)
            return DocumentDirectory(
                url: url,
                modificationDate: values.contentModificationDate ?? .distantPast,
                byteCount: byteCount
            )
        }
    }

    private func ownedByteCount(in documentDirectory: URL) throws -> Int64 {
        try fileManager.contentsOfDirectory(
            at: documentDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ).reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey])).flatMap(\.fileSize) ?? 0)
        }
    }

    private func isSafeToRemoveStoreDocumentDirectory(_ documentDirectory: URL) throws -> Bool {
        let contents = try fileManager.contentsOfDirectory(
            at: documentDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        )
        return !contents.isEmpty && contents.allSatisfy { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true && Self.isOwnedCopyFilename(url.lastPathComponent)
        }
    }

    private static func prepare(content: Data, fingerprint: Data) throws -> PreparedContent {
        guard let root = try JSONSerialization.jsonObject(with: content, options: []) as? [String: Any],
              let type = root["type"] as? String,
              type == "excalidraw",
              let version = versionString(from: root["version"]),
              root["elements"] is [Any],
              root["appState"] is [String: Any],
              root["files"] is [String: Any] else {
            throw RecoveryError.invalidExcalidrawPayload
        }

        return PreparedContent(
            data: content,
            version: version,
            fingerprint: fingerprint
        )
    }

    private static func versionString(from value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            return value.stringValue
        }
        return nil
    }

    private static func documentDirectoryName(for documentID: String) -> String {
        SHA256.hash(data: Data(documentID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func safeFilenameStem(name: String, version: String) -> String {
        "\(safeFilenameComponent(name, fallback: "untitled"))-v\(safeFilenameComponent(version, fallback: "unknown"))"
    }

    private static func safeFilenameComponent(_ value: String, fallback: String) -> String {
        let permitted = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = value.unicodeScalars.map { scalar in
            permitted.contains(scalar) ? String(scalar) : "_"
        }.joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "._"))
        let limited = String(sanitized.prefix(80))
        return limited.isEmpty ? fallback : limited
    }

    private static func suffix(after prefix: String, in filename: String) -> String {
        String(filename.dropFirst(prefix.count))
    }

    private static func isDocumentDirectoryName(_ name: String) -> Bool {
        guard name.count == 64 else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
        }
    }

    private static func isOwnedCopyFilename(_ filename: String) -> Bool {
        ["current-", "previous-", ".incoming-", ".holding-"].contains { prefix in
            filename.hasPrefix(prefix) && filename.hasSuffix(".excalidraw")
        }
    }
}
