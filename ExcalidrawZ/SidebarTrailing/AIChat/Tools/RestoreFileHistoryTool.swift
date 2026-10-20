//
//  RestoreFileHistoryTool.swift
//  ExcalidrawZ
//
//  Restores a file to a specific checkpoint snapshot.
//
//  - Looks up the file + checkpoint by UUID.
//  - Loads checkpoint content (iCloud Drive path or fallback to Core Data).
//  - Writes content back to the file (Core Data + iCloud Drive storage).
//  - If the restored file is the currently active file in the canvas,
//    triggers a coordinator reload so the user sees the change immediately.
//
//  Phase 4 will add a UI approval gate around this — destructive op, user
//  needs to explicitly OK. For now, executes without prompt; the caller
//  (the AI) is expected to confirm with the user via chat first.
//

import Foundation
import CoreData
import LLMCore

struct RestoreFileHistoryTool: Tool {
    /// Optional context. When present we use `canvasTarget` to refresh the
    /// canvas if the restored file is currently active. Without it, the
    /// restore still writes correctly — the user just won't see the
    /// change until they re-open the file.
    struct RestoreContext: ToolContext {
        var canvasTarget: ExcalidrawCoordinatorRegistry.CanvasTarget
    }

    var name: String { "restore_file_history" }

    var displayName: String { String(localizable: .aiChatToolRestoreFileHistoryName) }

    var description: String {
        """
        Restore a drawing file to a specific checkpoint. The file's current \
        content is OVERWRITTEN with the checkpoint's content. This is \
        destructive — confirm with the user in chat before calling. Get \
        valid (file_id, checkpoint_id) pairs from `query_file_history`.
        """
    }

    var inputSchema: ToolInputSchema {
        .parameters(ToolParameters(
            properties: [
                "file_id": ParameterProperty(
                    type: "string",
                    description: "UUID of the file to restore."
                ),
                "checkpoint_id": ParameterProperty(
                    type: "string",
                    description: "UUID of the checkpoint to restore from. Must belong to file_id."
                )
            ],
            required: ["file_id", "checkpoint_id"]
        ))
    }

    /// Restores overwrite the file's current content — always require user
    /// approval before executing. The user can opt to "always allow" within
    /// the conversation, in which case subsequent restores within the same
    /// conversation skip the prompt (LLMKit caches the decision).
    var approvalRequirement: ApprovalRequirement { .always }

    func execute(_ input: String, context: (any ChatInvocationContext)?) async throws -> ToolResult {
        try AIChatToolExecutionGate.ensureAIEnabled()

        let params = try parseInput(input)

        let coreData = PersistenceController.shared
        let resolveCtx = coreData.newTaskContext()

        // 1. Resolve file + checkpoint object IDs, sanity-check the
        //    relationship (don't restore a checkpoint from file A onto
        //    file B — would be a silent corruption).
        let resolution: Resolution = try await resolveCtx.perform {
            let fileFetch = NSFetchRequest<File>(entityName: "File")
            fileFetch.predicate = NSPredicate(format: "id == %@", params.fileUUID as CVarArg)
            fileFetch.fetchLimit = 1
            guard let file = try resolveCtx.fetch(fileFetch).first else {
                throw ToolError.executionFailed("File not found: \(params.fileID)")
            }

            let cpFetch = NSFetchRequest<FileCheckpoint>(entityName: "FileCheckpoint")
            cpFetch.predicate = NSPredicate(format: "id == %@", params.checkpointUUID as CVarArg)
            cpFetch.fetchLimit = 1
            guard let checkpoint = try resolveCtx.fetch(cpFetch).first else {
                throw ToolError.executionFailed("Checkpoint not found: \(params.checkpointID)")
            }
            guard checkpoint.file?.objectID == file.objectID else {
                throw ToolError.executionFailed(
                    "Checkpoint \(params.checkpointID) doesn't belong to file \(params.fileID)."
                )
            }
            guard let fileID = file.id else {
                throw ToolError.executionFailed("File has no UUID: \(params.fileID)")
            }
            return Resolution(
                fileObjectID: file.objectID,
                checkpointObjectID: checkpoint.objectID,
                fileID: fileID,
                fileName: file.name,
                checkpointSource: nil,
                checkpointUpdatedAt: nil
            )
        }
        guard try await LockedContentAIGuard.canToolAccess(fileObjectID: resolution.fileObjectID) else {
            return LockedContentAIGuard.lockedToolResult
        }

        let restoredContent = try await coreData.checkpointRepository.loadCheckpointContent(
            checkpointObjectID: resolution.checkpointObjectID
        )

        // 2. Run the actual restore through the existing repository
        //    method. It updates Core Data; storage save is on us.
        try await coreData.checkpointRepository.restoreCheckpoint(
            checkpointObjectID: resolution.checkpointObjectID,
            to: resolution.fileObjectID
        )
        try await coreData.fileRepository.saveFileContentToStorage(
            fileObjectID: resolution.fileObjectID,
            content: restoredContent
        )
        try await restoreCurrentFilename(
            resolution.fileName,
            fileObjectID: resolution.fileObjectID
        )

        var postRestoreWarning: String?
        let postRestoreCheckpointID: UUID?
        do {
            postRestoreCheckpointID = try await coreData.fileRepository.recordCheckpoint(
                fileObjectID: resolution.fileObjectID,
                content: restoredContent,
                source: .restorePost,
                description: restoreCheckpointDescription(
                    phase: "Restore",
                    checkpointID: params.checkpointID
                )
            )
        } catch {
            postRestoreCheckpointID = nil
            postRestoreWarning = " Post-restore checkpoint failed: \(error.localizedDescription)"
        }

        // 3. If we have a canvas context AND the restored file matches
        //    the canvas's current file, force a reload so the user sees
        //    the change without remounting. If context is missing or
        //    the file isn't currently displayed, the next file load
        //    will pick up the new content naturally.
        if let context,
           let restoreContext = try? context.resolve(RestoreContext.self) {
            await reloadCanvasIfActive(
                fileID: resolution.fileID,
                content: restoredContent,
                canvasTarget: restoreContext.canvasTarget
            )
        }

        let metadataCtx = coreData.newTaskContext()
        let metadata: Resolution = try await metadataCtx.perform {
            guard let file = try metadataCtx.existingObject(with: resolution.fileObjectID) as? File,
                  let checkpoint = try metadataCtx.existingObject(with: resolution.checkpointObjectID) as? FileCheckpoint else {
                throw ToolError.executionFailed("File or checkpoint disappeared during restore.")
            }
            return Resolution(
                fileObjectID: resolution.fileObjectID,
                checkpointObjectID: resolution.checkpointObjectID,
                fileID: resolution.fileID,
                fileName: file.name ?? "Untitled",
                checkpointSource: checkpoint.checkpointSource.rawValue,
                checkpointUpdatedAt: checkpoint.updatedAt
            )
        }
        let timestampString = metadata.checkpointUpdatedAt
            .map(ISO8601DateFormatter.shared.string(from:)) ?? "unknown"
        return .text(
            "Restored file '\(metadata.fileName ?? "Untitled")' to checkpoint " +
            "(\(metadata.checkpointSource ?? "unknown"), \(timestampString)). " +
            "Restore checkpoint: \(postRestoreCheckpointID?.uuidString ?? "unavailable")." +
            (postRestoreWarning ?? "")
        )
    }

    // MARK: - Helpers

    private struct Params {
        var fileID: String
        var checkpointID: String
        // File.id and FileCheckpoint.id are UUID attributes: a String
        // argument never matched them in the fetch predicates.
        var fileUUID: UUID
        var checkpointUUID: UUID
    }

    private func parseInput(_ input: String) throws -> Params {
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError.invalidInput("Expected JSON object with `file_id` and `checkpoint_id`.")
        }
        guard let fileID = json["file_id"] as? String, !fileID.isEmpty else {
            throw ToolError.invalidInput("Missing required parameter: file_id")
        }
        guard let checkpointID = json["checkpoint_id"] as? String, !checkpointID.isEmpty else {
            throw ToolError.invalidInput("Missing required parameter: checkpoint_id")
        }
        guard let fileUUID = UUID(uuidString: fileID) else {
            throw ToolError.invalidInput("file_id must be a UUID.")
        }
        guard let checkpointUUID = UUID(uuidString: checkpointID) else {
            throw ToolError.invalidInput("checkpoint_id must be a UUID.")
        }
        return Params(
            fileID: fileID,
            checkpointID: checkpointID,
            fileUUID: fileUUID,
            checkpointUUID: checkpointUUID
        )
    }

    private struct Resolution {
        let fileObjectID: NSManagedObjectID
        let checkpointObjectID: NSManagedObjectID
        let fileID: UUID
        let fileName: String?
        let checkpointSource: String?
        let checkpointUpdatedAt: Date?
    }

    private func restoreCheckpointDescription(phase: String, checkpointID: String) -> String {
        "\(phase) checkpoint restore from \(checkpointID)"
    }

    private func restoreCurrentFilename(
        _ fileName: String?,
        fileObjectID: NSManagedObjectID
    ) async throws {
        guard let fileName else { return }
        let context = PersistenceController.shared.newTaskContext()
        try await context.perform {
            guard let file = try context.existingObject(with: fileObjectID) as? File else {
                throw ToolError.executionFailed("File disappeared during restore.")
            }
            file.name = fileName
            try context.save()
        }
    }

    /// Reload the canvas only if the restored file is currently active.
    /// We bridge through `ExcalidrawCoordinatorRegistry.shared.coordinator(for:)`
    /// instead of going through `FileState` because tools don't have a
    /// fileState reference — the registry is the singleton seam built
    /// for this kind of cross-thread access.
    @MainActor
    private func reloadCanvasIfActive(
        fileID: UUID,
        content: Data,
        canvasTarget: ExcalidrawCoordinatorRegistry.CanvasTarget
    ) async {
        guard let coordinator = ExcalidrawCoordinatorRegistry.shared.coordinator(for: canvasTarget) else {
            return
        }
        guard coordinator.documentSyncController.currentLoadedFileID == fileID.uuidString else {
            return
        }
        await coordinator.documentSyncController.load(
            fileID: fileID.uuidString,
            data: content,
            force: true,
            validateCurrentParentFile: false
        )
    }
}
