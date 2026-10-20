//
//  PersistenceController+Migrate&Prepare.swift
//  ExcalidrawZ
//
//  Created by Dove Zachary on 3/25/25.
//

import Foundation
@preconcurrency import CoreData

extension PersistenceController {
    func prepare() {
        Task {
            do {
                // Create default and trash groups if they don't exist
                _ = try await self.groupRepository.createDefaultGroupIfNeeded()
                _ = try await self.groupRepository.createTrashGroupIfNeeded()
            } catch {
                logger.error("Failed to prepare default groups: \(error)")
            }

            // Fallback behavior: Move trashed files from trash group to default group
            do {
                // Only files still in the legacy trash group; fetching every
                // file at each launch to test this in memory was wasted work.
                let filesFetch: NSFetchRequest<File> = NSFetchRequest(entityName: "File")
                filesFetch.predicate = NSPredicate(format: "group.type == %@", Group.GroupType.trash.rawValue)
                let groupsFetch: NSFetchRequest<Group> = NSFetchRequest(entityName: "Group")

                let context = self.newTaskContext()
                try await context.perform {
                    let files = try filesFetch.execute()
                    let groups = try groupsFetch.execute()

                    let defaultGroup = groups.first { $0.groupType == .default }
                    var didChange = false

                    files.forEach { file in
                        if file.group?.groupType == .trash {
                            file.group = defaultGroup
                            file.inTrash = true
                            file.deletedAt = .now
                            didChange = true
                        }
                    }

                    if didChange {
                        try context.save()
                    }
                }
            } catch {
                logger.error("Failed to prepare fallback trash state: \(error)")
            }
        }
    }
}
