//
//  ExcalidrawDocumentAppStateSnapshotSaver.swift
//  ExcalidrawZ
//
//  Persists appState-only canvas changes without pulling a full content snapshot.
//

import Foundation
import UniformTypeIdentifiers

final class ExcalidrawDocumentAppStateSnapshotSaver: @unchecked Sendable {
    private let lock = NSLock()
    private weak var delegate: ExcalidrawDocumentSnapshotCoordinatorDelegate?

    private var commitTask: Task<Void, Never>?
    private var latestAppState: ExcalidrawCore.JSONValue?
    private var latestAppStateFileID: String?
    private var latestPersistentAppStateDirty = false
    private var latestViewportDirty = false

    private let trailingDebounceNanoseconds: UInt64 = 2_000_000_000

    func attach(delegate: ExcalidrawDocumentSnapshotCoordinatorDelegate) {
        self.delegate = delegate
    }

    func reset() {
        clear()
    }

    func recordLatestAppState(_ metadata: ExcalidrawCore.StateChangedMetadata) {
        guard metadata.shouldPersistAppStateFields || metadata.shouldPersistViewport,
              let appState = metadata.appState else {
            return
        }

        lock.lock()
        latestAppState = appState
        latestPersistentAppStateDirty = latestPersistentAppStateDirty || metadata.shouldPersistAppStateFields
        latestViewportDirty = latestViewportDirty || metadata.shouldPersistViewport
        lock.unlock()
    }

    func clear(cancelTask: Bool = true) {
        lock.lock()
        clearLocked(cancelTask: cancelTask)
        lock.unlock()
    }

    func schedule(
        _ metadata: ExcalidrawCore.StateChangedMetadata,
        currentFileID: String?,
        savingType: UTType?
    ) {
        guard metadata.shouldPersistAppStateFields || metadata.shouldPersistViewport,
              metadata.appState != nil,
              savingType == nil || savingType == .excalidrawFile else {
            return
        }

        lock.lock()
        latestAppStateFileID = metadata.currentFileId ?? currentFileID
        commitTask?.cancel()
        commitTask = makeCommitTask(delay: trailingDebounceNanoseconds)
        lock.unlock()
    }

    func flush(reason: String) async {
        cancelScheduledCommit()
        await commit(reason: reason)
    }

    func flushToCapturedTarget(
        reason: String,
        expectedFileID: String,
        target: FileState.CapturedCanvasSaveTarget,
        capturedContent: Data?
    ) async throws {
        cancelScheduledCommit()
        guard let core = delegate?.snapshotCoordinatorCore else { return }
        let commitState = takePendingCommitState()
        guard commitState.expectedFileID == expectedFileID,
              let appState = commitState.appState,
              commitState.persistentAppStateDirty || commitState.viewportDirty else {
            return
        }

        let persistenceAppState = try await appStateForPersistence(
            appState,
            fileID: expectedFileID,
            target: target
        )
        guard commitState.persistentAppStateDirty,
              let capturedContent else {
            return
        }
        guard let contentWithAppState = try Self.mergingAppStateIfSemanticallyChanged(
            persistenceAppState,
            into: capturedContent,
            nativeFileName: nativeFileName(for: target)
        ) else {
            return
        }
        try await FileState.persistCapturedAppStateOnlyUpdate(
            target,
            content: contentWithAppState
        )
        core.logger.debug("Committed background appState-only canvas update: \(reason) id=\(expectedFileID)")
    }

    func flushCurrentAppState(reason: String) async -> Bool {
        cancelScheduledCommit()
        guard let core = delegate?.snapshotCoordinatorCore else { return false }

        do {
            let state = await MainActor.run {
                (
                    currentFileID: core.parent?.file?.id,
                    content: core.parent?.file?.content,
                    type: core.parent?.type,
                    savingType: core.parent?.savingType,
                    fileName: core.parent?.fileState.currentActiveFile?.name
                )
            }
            guard state.savingType == nil || state.savingType == .excalidrawFile else {
                return false
            }
            guard state.type != .collaboration,
                  let expectedFileID = state.currentFileID,
                  let content = state.content else {
                return false
            }

            let loadedID = core.documentSyncController.currentLoadedFileID
            guard loadedID == expectedFileID else {
                core.logger.debug(
                    "Skipped forced appState-only canvas update \(reason): loaded file mismatch expected=\(expectedFileID) loaded=\(loadedID ?? "nil")"
                )
                return false
            }

            let appState = try await core.getCurrentAppState()
            let persistenceAppState = try await appStateForPersistence(
                appState,
                fileID: expectedFileID,
                core: core
            )
            if await core.parent?.onPersistSnapshot != nil {
                if try Self.isAppStateSemanticallyChanged(persistenceAppState, in: content) {
                    try await core.documentSyncController.persistCurrentAppStateSnapshot(fileID: expectedFileID)
                }
                clear()
                return true
            }
            guard let contentWithAppState = try Self.mergingAppStateIfSemanticallyChanged(
                persistenceAppState,
                into: content,
                nativeFileName: state.fileName
            ) else {
                clear()
                return true
            }
            await MainActor.run {
                core.parent?.fileState.updateAppStateOnlyForCurrentFile(
                    expectedFileID: expectedFileID,
                    content: contentWithAppState
                )
            }
            clear()
            core.logger.debug("Committed forced appState-only canvas update: \(reason) id=\(expectedFileID)")
            return true
        } catch is CancellationError {
            return false
        } catch {
            core.logger.error("Failed to apply forced appState-only canvas update: \(error)")
            core.publishError(error)
            return false
        }
    }

    private func makeCommitTask(delay: UInt64) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
                try Task.checkCancellation()
                await self?.commit(reason: "appStateOnlyDebounced")
            } catch {
                return
            }
        }
    }

    private func commit(reason: String) async {
        guard let core = delegate?.snapshotCoordinatorCore else { return }
        let commitState = takePendingCommitState()
        guard let expectedFileID = commitState.expectedFileID,
              let appState = commitState.appState,
              commitState.persistentAppStateDirty || commitState.viewportDirty else {
            return
        }

        do {
            let state = await MainActor.run {
                (
                    currentFileID: core.parent?.file?.id,
                    content: core.parent?.file?.content,
                    type: core.parent?.type,
                    savingType: core.parent?.savingType,
                    fileName: core.parent?.fileState.currentActiveFile?.name
                )
            }
            guard state.savingType == nil || state.savingType == .excalidrawFile else {
                return
            }
            guard state.type != .collaboration,
                  state.currentFileID == expectedFileID else {
                return
            }

            let persistenceAppState = try await appStateForPersistence(
                appState,
                fileID: expectedFileID,
                core: core
            )
            guard commitState.persistentAppStateDirty,
                  let content = state.content else {
                return
            }
#if DEBUG
            logSemanticAppStateChangesIfNeeded(
                core: core,
                reason: reason,
                fileID: expectedFileID,
                appState: persistenceAppState,
                content: content
            )
#endif
            if await core.parent?.onPersistSnapshot != nil {
                // Only meaningful persisted preferences reach here: panning,
                // selection and transient UI state never trigger a full save.
                // Snapshot at save time instead of writing stale captured elements;
                // the merged document would be discarded, so only compare.
                guard try Self.isAppStateSemanticallyChanged(persistenceAppState, in: content) else { return }
                core.documentSyncController.schedulePersistentAppStateSnapshot(fileID: expectedFileID)
                return
            }
            guard let contentWithAppState = try Self.mergingAppStateIfSemanticallyChanged(
                persistenceAppState,
                into: content,
                nativeFileName: state.fileName
            ) else {
                return
            }
            await MainActor.run {
                core.parent?.fileState.updateAppStateOnlyForCurrentFile(
                    expectedFileID: expectedFileID,
                    content: contentWithAppState
                )
            }
        } catch {
            core.logger.error("Failed to apply appState-only canvas update: \(error)")
            core.publishError(error)
        }
    }

    private func cancelScheduledCommit() {
        lock.lock()
        commitTask?.cancel()
        commitTask = nil
        lock.unlock()
    }

    private func takePendingCommitState() -> (
        expectedFileID: String?,
        appState: ExcalidrawCore.JSONValue?,
        persistentAppStateDirty: Bool,
        viewportDirty: Bool
    ) {
        lock.lock()
        let fileID = latestAppStateFileID
        let appState = latestAppState
        let persistentAppStateDirty = latestPersistentAppStateDirty
        let viewportDirty = latestViewportDirty
        clearLocked(cancelTask: false)
        lock.unlock()
        return (fileID, appState, persistentAppStateDirty, viewportDirty)
    }

    private func appStateForPersistence(
        _ appState: ExcalidrawCore.JSONValue,
        fileID: String,
        core: ExcalidrawCore
    ) async throws -> ExcalidrawCore.JSONValue {
        guard await usesLocalViewportSidecar(fileID: fileID, core: core) else {
            return appState
        }

        return try await ExcalidrawViewportStateStore.shared.appStateBySeparatingViewport(
            appState,
            fileID: fileID
        )
    }

    private func appStateForPersistence(
        _ appState: ExcalidrawCore.JSONValue,
        fileID: String,
        target: FileState.CapturedCanvasSaveTarget
    ) async throws -> ExcalidrawCore.JSONValue {
        guard target.kind.usesLocalViewportSidecar else {
            return appState
        }

        return try await ExcalidrawViewportStateStore.shared.appStateBySeparatingViewport(
            appState,
            fileID: fileID
        )
    }

    private func usesLocalViewportSidecar(
        fileID: String,
        core: ExcalidrawCore
    ) async -> Bool {
        await MainActor.run {
            guard core.parent?.type == .normal,
                  let activeFile = core.parent?.fileState.currentActiveFile,
                  activeFile.usesLocalViewportSidecar else {
                return false
            }
            return activeFile.id == fileID
        }
    }

#if DEBUG
    private func logSemanticAppStateChangesIfNeeded(
        core: ExcalidrawCore,
        reason: String,
        fileID: String,
        appState: ExcalidrawCore.JSONValue,
        content: Data
    ) {
        do {
            let changedKeys = try Self.changedSemanticAppStateKeys(
                appState,
                in: content
            )
            guard !changedKeys.isEmpty else { return }

            core.logger.debug(
                "AppState-only semantic changes \(reason) id=\(fileID) keys=\(changedKeys.joined(separator: ","))"
            )
        } catch {
            core.logger.debug("Failed to diff appState-only semantic changes: \(error.localizedDescription)")
        }
    }
#endif

    private func clearLocked(cancelTask: Bool = true) {
        if cancelTask {
            commitTask?.cancel()
        }
        commitTask = nil
        latestAppState = nil
        latestAppStateFileID = nil
        latestPersistentAppStateDirty = false
        latestViewportDirty = false
    }

    /// Same decision as `mergingAppStateIfSemanticallyChanged` returning non-nil,
    /// without building and serializing the merged document.
    static func isAppStateSemanticallyChanged(
        _ appState: ExcalidrawCore.JSONValue,
        in content: Data
    ) throws -> Bool {
        let appStateObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(appState))
        let existingAppStateObject: Any
        // Only the stored appState is compared; do not parse every element.
        if let member = TopLevelJSONMember.locate("appState", in: content) {
            existingAppStateObject = try member.value(in: content).map {
                try JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed)
            } ?? [String: Any]()
        } else {
            guard let contentObject = try JSONSerialization.jsonObject(with: content) as? [String: Any] else {
                return true
            }
            existingAppStateObject = contentObject["appState"] ?? [String: Any]()
        }
        let existing = ExcalidrawDocumentAppStatePersistence.appStateObjectByKeepingAppStateOnlyPersistentFields(
            from: existingAppStateObject
        )
        let incoming = ExcalidrawDocumentAppStatePersistence.appStateObjectByKeepingAppStateOnlyPersistentFields(
            from: appStateObject
        )
        return try normalizedJSONData(existing) != normalizedJSONData(incoming)
    }

    static func mergingAppStateIfSemanticallyChanged(
        _ appState: ExcalidrawCore.JSONValue,
        into content: Data,
        nativeFileName: String?
    ) throws -> Data? {
        let appStateData = try JSONEncoder().encode(appState)
        let appStateObject = try JSONSerialization.jsonObject(with: appStateData)
        guard var contentObject = try JSONSerialization.jsonObject(with: content) as? [String: Any] else {
            return content
        }

        let existingAppStateObject = contentObject["appState"] ?? [String: Any]()
        let existingSemanticAppStateObject = ExcalidrawDocumentAppStatePersistence.appStateObjectByKeepingAppStateOnlyPersistentFields(
            from: existingAppStateObject
        )
        let newSemanticAppStateObject = ExcalidrawDocumentAppStatePersistence.appStateObjectByKeepingAppStateOnlyPersistentFields(
            from: appStateObject
        )
        guard try normalizedJSONData(existingSemanticAppStateObject) != normalizedJSONData(newSemanticAppStateObject) else {
            return nil
        }

        contentObject["appState"] = ExcalidrawDocumentAppStatePersistence.appStateObjectByMergingAppStateOnlyPersistentFields(
            from: appStateObject,
            into: existingAppStateObject,
            nativeFileName: nativeFileName
        )
        return try JSONSerialization.data(withJSONObject: contentObject)
    }

#if DEBUG
    private static func changedSemanticAppStateKeys(
        _ appState: ExcalidrawCore.JSONValue,
        in content: Data
    ) throws -> [String] {
        let appStateData = try JSONEncoder().encode(appState)
        let newAppStateObject = try JSONSerialization.jsonObject(with: appStateData)
        guard let newAppStateDictionary = newAppStateObject as? [String: Any],
              let contentObject = try JSONSerialization.jsonObject(with: content) as? [String: Any] else {
            return []
        }

        let existingAppStateObject = contentObject["appState"] ?? [String: Any]()
        let existingAppState = ExcalidrawDocumentAppStatePersistence.appStateObjectByKeepingAppStateOnlyPersistentFields(
            from: existingAppStateObject
        )
        let newAppState = ExcalidrawDocumentAppStatePersistence.appStateObjectByKeepingAppStateOnlyPersistentFields(
            from: newAppStateDictionary
        )

        return try Set(existingAppState.keys)
            .union(newAppState.keys)
            .filter { key in
                try normalizedJSONData(existingAppState[key] ?? NSNull()) != normalizedJSONData(newAppState[key] ?? NSNull())
            }
            .sorted()
    }
#endif

    private static func normalizedJSONData(_ object: Any) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: ["value": object],
            options: [.sortedKeys]
        )
    }

    private func nativeFileName(for target: FileState.CapturedCanvasSaveTarget) -> String? {
        target.kind.nativeFileName
    }

}
