//
//  BackupsSettingsView+Export.swift
//  ExcalidrawZ
//
//  Created by Codex on 2026/06/01.
//

import CoreData
import Foundation

#if os(macOS)
func isAppEncryptedBackupFile(_ url: URL) -> Bool {
    guard let data = try? Data(contentsOf: url) else { return false }
    return EncryptedBackupService.isEncryptedEnvelope(data)
}

func isRecoveryKeyEncryptedBackupFile(_ url: URL) -> Bool {
    guard let data = try? Data(contentsOf: url) else { return false }
    return EncryptedContentService.isEncryptedEnvelope(data)
}

func backupContainsEncryptedExcalidrawFiles(_ backup: URL) throws -> Bool {
    try backupDirectoryContainsEncryptedExcalidrawFiles(backup)
}

func exportBackupRecord(
    from backup: URL,
    to targetURL: URL,
    context: NSManagedObjectContext,
    recoveryKey: RecoveryKey?
) async throws {
    let fileManager = FileManager.default
    let replacementDirectory = try fileManager.url(
        for: .itemReplacementDirectory,
        in: .userDomainMask,
        appropriateFor: targetURL.deletingLastPathComponent(),
        create: true
    )
    defer {
        try? fileManager.removeItem(at: replacementDirectory)
    }

    let stagingURL = replacementDirectory.appendingPathComponent(targetURL.lastPathComponent, conformingTo: .directory)
    try await writeExportedBackupRecord(
        from: backup,
        to: stagingURL,
        context: context,
        recoveryKey: recoveryKey
    )

    // Replace atomically: removing the old export before copying would lose it
    // if the copy failed. Staging is on the target's volume, so this is a move.
    if fileManager.fileExists(atPath: targetURL.path) {
        _ = try fileManager.replaceItemAt(targetURL, withItemAt: stagingURL)
    } else {
        try fileManager.moveItem(at: stagingURL, to: targetURL)
    }
}

private func writeExportedBackupRecord(
    from backup: URL,
    to targetURL: URL,
    context: NSManagedObjectContext,
    recoveryKey: RecoveryKey?
) async throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: false)

    guard let enumerator = fileManager.enumerator(
        at: backup,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        return
    }

    while let sourceURL = enumerator.nextObject() as? URL {
        let destinationURL = exportedBackupDestinationURL(
            sourceURL: sourceURL,
            backupRoot: backup,
            exportRoot: targetURL
        )
        let isDirectory = (try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true

        if isDirectory {
            try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            continue
        }

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let data: Data
        if sourceURL.pathExtension == "excalidraw" {
            data = try await exportedBackupExcalidrawFileData(
                from: sourceURL,
                context: context,
                recoveryKey: recoveryKey
            )
        } else {
            data = try EncryptedBackupService.decryptIfNeeded(Data(contentsOf: sourceURL))
        }
        try data.write(to: destinationURL, options: .atomic)
    }
}

private func exportedBackupDestinationURL(
    sourceURL: URL,
    backupRoot: URL,
    exportRoot: URL
) -> URL {
    let backupComponents = backupRoot.standardizedFileURL.pathComponents
    let sourceComponents = sourceURL.standardizedFileURL.pathComponents
    let relativeComponents = sourceComponents.dropFirst(backupComponents.count)

    return relativeComponents.reduce(exportRoot) { partialResult, component in
        partialResult.appendingPathComponent(component)
    }
}

private func exportedBackupExcalidrawFileData(
    from sourceURL: URL,
    context: NSManagedObjectContext,
    recoveryKey: RecoveryKey?
) async throws -> Data {
    let storedData = try EncryptedBackupService.decryptIfNeeded(Data(contentsOf: sourceURL))

    guard EncryptedContentService.isEncryptedEnvelope(storedData) else {
        return storedData
    }

    guard let recoveryKey else {
        throw LockedContentSystemUnlockError.noSavedRecoveryKey
    }

    let excalidrawFile = try await unlockedEncryptedBackupExcalidrawFile(
        from: sourceURL,
        context: context,
        recoveryKey: recoveryKey
    )
    return excalidrawFile.content ?? storedData
}

func unlockedEncryptedBackupExcalidrawFile(
    from sourceURL: URL,
    context: NSManagedObjectContext,
    recoveryKey: RecoveryKey
) async throws -> ExcalidrawFile {
    try await backupExcalidrawFile(
        from: sourceURL,
        context: context,
        recoveryKey: recoveryKey
    )
}

func backupExcalidrawFile(
    from sourceURL: URL,
    context: NSManagedObjectContext,
    recoveryKey: RecoveryKey?
) async throws -> ExcalidrawFile {
    let storedData = try EncryptedBackupService.decryptIfNeeded(Data(contentsOf: sourceURL))
    guard EncryptedContentService.isEncryptedEnvelope(storedData) else {
        var excalidrawFile = try ExcalidrawFile(data: storedData)
        if excalidrawFile.name == nil {
            excalidrawFile.name = sourceURL.deletingPathExtension().lastPathComponent
        }
        try await excalidrawFile.syncFiles(context: context)
        return excalidrawFile
    }

    guard let recoveryKey else {
        throw LockedContentSystemUnlockError.noSavedRecoveryKey
    }

    let envelope = try EncryptedContentService.decodeEnvelope(storedData)
    let plaintext = try EncryptedContentService.decrypt(storedData, recoveryKey: recoveryKey)
    let fileID = envelope.contentType == "file" ? envelope.contentID : nil

    var excalidrawFile = try ExcalidrawFile(data: plaintext, id: fileID)
    if excalidrawFile.name == nil {
        excalidrawFile.name = sourceURL.deletingPathExtension().lastPathComponent
    }
    try await excalidrawFile.syncFiles(context: context)
    return excalidrawFile
}
#endif
