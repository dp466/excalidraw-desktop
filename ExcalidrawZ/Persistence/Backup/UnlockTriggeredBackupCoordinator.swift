//
//  UnlockTriggeredBackupCoordinator.swift
//  ExcalidrawZ
//
//  Created by Codex on 2026/05/31.
//

import Foundation
import Logging
import CoreData

#if canImport(AppKit)
actor UnlockTriggeredBackupCoordinator {
    static let shared = UnlockTriggeredBackupCoordinator()

    private static let logger = Logger(label: "UnlockTriggeredBackupCoordinator")
    private static let backupDelay: Duration = .seconds(2)

    func noteLockedContentUnlocked(fileID: String) {
        let day = Self.dayIdentifier(for: Date())
        Task(priority: .utility) { [day, fileID] in
            do {
                try await Task.sleep(for: Self.backupDelay)
                let context = PersistenceController.shared.container.newBackgroundContext()
                let alreadyBackedUp = try await Self.backupContainsFile(
                    fileID: fileID,
                    day: day,
                    context: context
                )
                guard !alreadyBackedUp else {
                    return
                }

                let didBackup = try await backupFiles(context: context, reason: .unlockedContent)
                if didBackup {
                    Self.logger.info("Unlock-triggered backup completed for \(day)")
                }
            } catch is CancellationError {
            } catch {
                Self.logger.error("Unlock-triggered backup failed: \(error.localizedDescription)")
            }
        }
    }

    private static func backupContainsFile(
        fileID: String,
        day: String,
        context: NSManagedObjectContext
    ) async throws -> Bool {
        guard let backupLocation = try await backupLocation(for: fileID, day: day, context: context) else {
            return false
        }

        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: backupLocation.groupURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else {
            return false
        }

        return fileURLs.contains { url in
            guard url.pathExtension == "excalidraw" else { return false }
            return backupFilename(
                url.deletingPathExtension().lastPathComponent,
                matches: backupLocation.fileName
            )
        }
    }

    private static func backupLocation(
        for fileID: String,
        day: String,
        context: NSManagedObjectContext
    ) async throws -> (groupURL: URL, fileName: String)? {
        guard let fileUUID = UUID(uuidString: fileID) else {
            return nil
        }

        let fallbackFileName = String(localizable: .newFileNamePlaceholder)
        let fileInfo: (groupPath: [String], fileName: String)? = try await context.perform {
            let fetchRequest = NSFetchRequest<File>(entityName: "File")
            fetchRequest.fetchLimit = 1
            fetchRequest.predicate = NSPredicate(format: "id == %@", fileUUID as CVarArg)

            guard let file = try context.fetch(fetchRequest).first,
                  let group = file.group else {
                return nil
            }

            var groups: [Group] = []
            var currentGroup: Group? = group
            while let group = currentGroup {
                groups.insert(group, at: 0)
                currentGroup = group.parent
            }

            // Same names as the backup writer, which makes them disk-safe; raw
            // names with "/" or ":" never matched and re-ran the backup.
            return (
                groupPath: groups.map { FileRepository.diskSafeName($0.name ?? "Untitled") },
                fileName: FileRepository.diskSafeName(file.name ?? fallbackFileName)
            )
        }

        guard let fileInfo else {
            return nil
        }

        var groupURL = try getBackupsDir()
            .appendingPathComponent(day, conformingTo: .directory)
            .appendingPathComponent("Cloud", conformingTo: .directory)
        for component in fileInfo.groupPath {
            groupURL = groupURL.appendingPathComponent(component, conformingTo: .directory)
        }
        return (groupURL, fileInfo.fileName)
    }

    private static func backupFilename(_ filename: String, matches fileName: String) -> Bool {
        if filename == fileName {
            return true
        }

        guard filename.hasPrefix("\(fileName) ("),
              filename.hasSuffix(")") else {
            return false
        }

        let suffixStart = filename.index(filename.startIndex, offsetBy: fileName.count + 2)
        let suffix = filename[suffixStart..<filename.index(before: filename.endIndex)]
        return Int(suffix) != nil
    }

    private static func dayIdentifier(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}
#endif
