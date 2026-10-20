//
//  ExcalidrawDocumentSnapshotCoordinator.swift
//  ExcalidrawZ
//
//  Coordinates lightweight dirty notifications with full canvas snapshot saves.
//

import Foundation
import UniformTypeIdentifiers

protocol ExcalidrawDocumentSnapshotCoordinatorDelegate: AnyObject {
    var snapshotCoordinatorCore: ExcalidrawCore? { get }

    func snapshotCoordinatorCanApplyStateChanged(
        currentFileID: String?,
        webLoadedFileID: String?,
        isCollaboration: Bool
    ) -> Bool

    func snapshotCoordinatorApplyCanvasFileData(
        _ fileData: ExcalidrawCore.ExcalidrawFileData,
        currentFileID: String?,
        type: ExcalidrawCanvasView.ExcalidrawType?,
        savingType: UTType?,
        markProgrammaticCommit: Bool
    ) async throws

    func snapshotCoordinatorMakeFileData(
        from snapshot: ExcalidrawCore.CurrentFileSnapshot
    ) throws -> ExcalidrawCore.ExcalidrawFileData
}

/// Owns save cadence for live Excalidraw state.
///
/// The WebView reports cheap metadata on hot edit paths. This coordinator
/// routes that metadata into smaller save components and only asks for a full
/// snapshot on a bounded cadence or at file/app boundaries.
final class ExcalidrawDocumentSnapshotCoordinator: @unchecked Sendable {
    private weak var delegate: ExcalidrawDocumentSnapshotCoordinatorDelegate?

    private lazy var contentScheduler = ExcalidrawDocumentContentSnapshotScheduler { [weak self] in
        await self?.commitScheduledDirtySnapshot()
    }
    private let appStateSaver = ExcalidrawDocumentAppStateSnapshotSaver()
    private let programmaticCommitter = ExcalidrawDocumentProgrammaticSnapshotCommitter()

    init(delegate: ExcalidrawDocumentSnapshotCoordinatorDelegate? = nil) {
        if let delegate {
            attach(delegate: delegate)
        }
    }

    func attach(delegate: ExcalidrawDocumentSnapshotCoordinatorDelegate) {
        self.delegate = delegate
        appStateSaver.attach(delegate: delegate)
        programmaticCommitter.attach(delegate: delegate)
    }

    func reset() {
        contentScheduler.reset()
        appStateSaver.reset()
        programmaticCommitter.reset()
    }

    func cancelPendingSnapshotCommits() {
        reset()
    }

    func handleStateChangedMetadata(
        _ metadata: ExcalidrawCore.StateChangedMetadata,
        currentFileID: String?,
        type _: ExcalidrawCanvasView.ExcalidrawType?,
        savingType: UTType?
    ) async {
        guard metadata.hasAnyDirtyChanges else {
            contentScheduler.markClean(metadata.revision)
            appStateSaver.clear()
            return
        }

        contentScheduler.recordLatestRevision(metadata.revision)
        appStateSaver.recordLatestAppState(metadata)

        guard metadata.shouldPullContentSnapshot else {
            appStateSaver.schedule(
                metadata,
                currentFileID: currentFileID,
                savingType: savingType
            )
            return
        }

        appStateSaver.clear()
        contentScheduler.recordPendingContentDirtyMetadata(
            metadata,
            currentFileID: currentFileID
        )
    }

    func schedulePersistentAppStateSnapshot(fileID: String) {
        var metadata = ExcalidrawCore.StateChangedMetadata()
        metadata.currentFileId = fileID
        metadata.contentDirty = true
        contentScheduler.recordPendingContentDirtyMetadata(metadata, currentFileID: fileID)
    }

    @MainActor
    func scheduleProgrammaticMutationCommit(reason: String) {
        programmaticCommitter.schedule(reason: reason)
    }

    /// Forces a pending content-dirty notification to materialize into a full
    /// snapshot. Use this at boundaries such as file switches or app
    /// backgrounding; appState-only changes deliberately do not pull content.
    func flushPendingDirtySnapshot(
        reason: String,
        force: Bool = false,
        expectedFileID: String? = nil,
        validateParentFileID: Bool = true
    ) async {
        guard await contentScheduler.beginExclusiveFlush() else { return }
        defer { contentScheduler.endExclusiveFlush() }
        if let flushState = contentScheduler.takeFlushState() {
            await commitDirtySnapshot(
                reason: reason,
                expectedFileID: expectedFileID ?? flushState.expectedFileID,
                expectedRevision: flushState.expectedRevision,
                expectedGeneration: flushState.generation,
                requirePendingDirty: !force,
                validateParentFileID: validateParentFileID
            )
        } else if force {
            let didCommitCurrentAppState = await appStateSaver.flushCurrentAppState(reason: reason)
            if !didCommitCurrentAppState {
                await appStateSaver.flush(reason: reason)
            }
        } else {
            await appStateSaver.flush(reason: reason)
        }
    }

    @discardableResult
    func flushPendingDirtySnapshotToCapturedTarget(
        reason: String,
        expectedFileID: String,
        target: FileState.CapturedCanvasSaveTarget,
        forceCurrentSnapshot: Bool = false
    ) async -> Bool {
        let capturedContent = await MainActor.run {
            delegate?.snapshotCoordinatorCore?.parent?.file?.content
        }
        return await flushPendingDirtySnapshotToCapturedTarget(
            reason: reason,
            expectedFileID: expectedFileID,
            target: target,
            capturedContent: capturedContent,
            forceCurrentSnapshot: forceCurrentSnapshot
        )
    }

    private func commitScheduledDirtySnapshot() async {
        guard let commitState = contentScheduler.takeScheduledCommitState() else {
            return
        }
        defer {
            contentScheduler.completeScheduledCommit()
        }
        await commitDirtySnapshot(
            reason: "stateChangedThrottled",
            expectedFileID: commitState.expectedFileID,
            expectedRevision: commitState.expectedRevision,
            expectedGeneration: commitState.generation,
            requirePendingDirty: true,
            validateParentFileID: true
        )
    }

    /// Pulls the current full scene and applies it through the same
    /// persistence path as legacy full `onStateChanged`.
    private func commitDirtySnapshot(
        reason: String,
        expectedFileID: String?,
        expectedRevision: Int?,
        expectedGeneration: UInt64? = nil,
        requirePendingDirty: Bool = true,
        validateParentFileID: Bool = true
    ) async {
        guard let delegate,
              let core = delegate.snapshotCoordinatorCore else { return }
        if requirePendingDirty {
            guard contentScheduler.hasPendingDirtySnapshot() else { return }
        }

        let onError = core.publishError
        let parentFileID = await MainActor.run { core.parent?.file?.id }
        if validateParentFileID,
           let expectedFileID,
           parentFileID != expectedFileID {
            core.logger.debug(
                "Skipped dirty canvas snapshot \(reason): parent file mismatch expected=\(expectedFileID) actual=\(parentFileID ?? "nil")"
            )
            return
        }
        let currentFileID = expectedFileID ?? parentFileID

        let type = await MainActor.run { core.parent?.type }
        let savingType = await MainActor.run { core.parent?.savingType }

        do {
            let loadedID = core.documentSyncController.currentLoadedFileID
            guard delegate.snapshotCoordinatorCanApplyStateChanged(
                currentFileID: currentFileID,
                webLoadedFileID: loadedID,
                isCollaboration: type == .collaboration
            ) else {
                core.logger.debug(
                    "Skipped dirty canvas snapshot \(reason): loaded file mismatch expected=\(currentFileID ?? "nil") loaded=\(loadedID ?? "nil")"
                )
                return
            }

            let snapshot = try await core.getCurrentFileSnapshot()
            if let expectedRevision,
               let snapshotRevision = snapshot.revision,
               snapshotRevision < expectedRevision {
                core.logger.debug(
                    "Skipped dirty canvas snapshot \(reason): stale snapshot revision=\(snapshotRevision) expected=\(expectedRevision)"
                )
                return
            }
            let fileData = try delegate.snapshotCoordinatorMakeFileData(from: snapshot)
            try await delegate.snapshotCoordinatorApplyCanvasFileData(
                fileData,
                currentFileID: currentFileID,
                type: type,
                savingType: savingType,
                markProgrammaticCommit: false
            )
            contentScheduler.markCommitted(
                snapshotRevision: snapshot.revision,
                fallbackRevision: expectedRevision,
                generation: expectedGeneration
            )
        } catch is CancellationError {
            return
        } catch {
            core.logger.error("Failed to commit dirty canvas snapshot \(reason): \(error)")
            if await core.parent?.onPersistSnapshot != nil {
                await core.parent?.fileState.reportAutosaveFailure(
                    fileID: currentFileID, message: error.localizedDescription
                )
            } else {
                onError(error)
            }
        }
    }

    private func flushPendingDirtySnapshotToCapturedTarget(
        reason: String,
        expectedFileID: String,
        target: FileState.CapturedCanvasSaveTarget,
        capturedContent: Data?,
        forceCurrentSnapshot: Bool = false
    ) async -> Bool {
        guard await contentScheduler.beginExclusiveFlush() else { return false }
        defer { contentScheduler.endExclusiveFlush() }
        let flushState = contentScheduler.takeFlushState()
        if forceCurrentSnapshot || flushState != nil {
            return await commitDirtySnapshotToCapturedTarget(
                reason: reason,
                expectedFileID: expectedFileID,
                expectedRevision: flushState?.expectedRevision,
                target: target,
                capturedContent: capturedContent,
                skipIfStoredSceneMatches: flushState == nil
            )
        }

        do {
            try await appStateSaver.flushToCapturedTarget(
                reason: reason,
                expectedFileID: expectedFileID,
                target: target,
                capturedContent: capturedContent
            )
            return true
        } catch is CancellationError {
            return false
        } catch {
            if let core = delegate?.snapshotCoordinatorCore {
                core.logger.error("Failed to persist captured appState snapshot \(reason): \(error)")
                core.publishError(error)
            }
            return false
        }
    }

    @discardableResult
    private func commitDirtySnapshotToCapturedTarget(
        reason: String,
        expectedFileID: String,
        expectedRevision: Int?,
        target capturedTarget: FileState.CapturedCanvasSaveTarget,
        capturedContent: Data?,
        skipIfStoredSceneMatches: Bool = false
    ) async -> Bool {
        guard let delegate,
              let core = delegate.snapshotCoordinatorCore else { return false }
        // An in-app move or rename may have taken the file while it was open.
        // Follow it, so pending edits land in the moved file instead of
        // recreating the old one.
        var target = capturedTarget
        if case .localFile(let url, let newCheckpoint, let suppressCheckpoint) = target.kind,
           !(await Self.localFileExists(url)),
           let movedURL = ExcalidrawFile.currentLocation(ofMoved: url),
           await Self.localFileExists(movedURL) {
            target = FileState.CapturedCanvasSaveTarget(
                id: target.id,
                kind: .localFile(url: movedURL, newCheckpoint: newCheckpoint, suppressCheckpoint: suppressCheckpoint)
            )
            core.logger.info("Boundary snapshot follows moved file \(url.lastPathComponent) -> \(movedURL.lastPathComponent)")
        }
        do {
            let loadedID = core.documentSyncController.currentLoadedFileID
            guard loadedID == expectedFileID else {
                core.logger.debug(
                    "Skipped background dirty canvas snapshot \(reason): loaded file mismatch expected=\(expectedFileID) loaded=\(loadedID ?? "nil")"
                )
                return false
            }

            let snapshot = try await core.getCurrentFileSnapshot()
            if let expectedRevision,
               let snapshotRevision = snapshot.revision,
               snapshotRevision < expectedRevision {
                core.logger.debug(
                    "Skipped background dirty canvas snapshot \(reason): stale snapshot revision=\(snapshotRevision) expected=\(expectedRevision)"
                )
                return false
            }
            let fileData = try await capturedCanvasFileDataForPersistence(
                delegate.snapshotCoordinatorMakeFileData(from: snapshot),
                expectedFileID: expectedFileID,
                target: target
            )
            // A forced boundary save with nothing pending: when the live scene
            // equals the file on disk, do not rewrite it, bump its date, or add
            // a duplicate File History checkpoint just because it was viewed.
            // Disk is the comparison source and, on a mismatch, the base
            // envelope for the write, so both parses are reused.
            var parsedObjects: (stored: [String: Any]?, live: [String: Any]?)?
            if skipIfStoredSceneMatches, case .localFile(let url, _, _) = target.kind {
                // Comparison only: an uncoordinated, mapped read is enough. A torn
                // read can only cause a mismatch, which falls back to the full save.
                let storedRead: Result<Data, Error>
                do {
                    storedRead = .success(try await LocalFolder.withSecurityScopedAccessToContainingFolder(for: url) {
                        try Data(contentsOf: url, options: .mappedIfSafe)
                    })
                } catch {
                    storedRead = .failure(error)
                }
                // A missing destination is written normally: it may be a first save,
                // and an unsignalled edit must never be dropped.
                switch storedRead {
                    case .success(let stored):
                        let storedObject = ExcalidrawFile.parsedSceneObject(stored)
                        let live = ExcalidrawFile.parsedSceneObject(fileData.documentData)
                        parsedObjects = (storedObject, live)
                        if let storedObject, let live, ExcalidrawFile.sceneObject(storedObject, matches: live) {
                            contentScheduler.markCommitted(
                                snapshotRevision: snapshot.revision,
                                fallbackRevision: expectedRevision
                            )
                            core.logger.debug("Skipped unchanged boundary snapshot \(reason) id=\(expectedFileID)")
                            return true
                        }
                    case .failure:
                        break
                }
            }
            var file = ExcalidrawFile()
            file.id = expectedFileID
            file.content = capturedContent ?? file.content
            if let parsedObjects, parsedObjects.live != nil {
                // The file is persisted and discarded: only content and files are
                // used, so skip decoding every element into native models.
                file.apply(try ExcalidrawFile.prepareCanvasDataUpdate(
                    existingObject: parsedObjects.stored ?? capturedContent.flatMap(ExcalidrawFile.parsedSceneObject),
                    liveObject: parsedObjects.live,
                    data: fileData,
                    decodeElements: false
                ))
            } else if let content = file.content {
                file.apply(try ExcalidrawFile.prepareCanvasDataUpdate(
                    existingContent: content,
                    data: fileData,
                    decodeElements: false
                ))
            } else {
                try file.update(data: fileData)
            }
            try await FileState.persistCapturedCanvasUpdate(target, with: file)
            contentScheduler.markCommitted(
                snapshotRevision: snapshot.revision,
                fallbackRevision: expectedRevision
            )
            core.logger.debug("Committed background dirty canvas snapshot: \(reason) id=\(expectedFileID)")
            return true
        } catch is CancellationError {
            return false
        } catch {
            core.logger.error("Failed to commit background dirty canvas snapshot \(reason): \(error)")
            core.publishError(error)
            return false
        }
    }

    private static func localFileExists(_ url: URL) async -> Bool {
        (try? await LocalFolder.withSecurityScopedAccessToContainingFolder(for: url) {
            FileManager.default.fileExists(atPath: url.path)
        }) ?? false
    }

    private func capturedCanvasFileDataForPersistence(
        _ fileData: ExcalidrawCore.ExcalidrawFileData,
        expectedFileID: String,
        target: FileState.CapturedCanvasSaveTarget
    ) async throws -> ExcalidrawCore.ExcalidrawFileData {
        var fileDataForPersistence = fileData

        if target.kind.usesLocalViewportSidecar {
            fileDataForPersistence.documentData = try await ExcalidrawViewportStateStore.shared
                .contentDataBySeparatingViewport(
                    from: fileDataForPersistence.documentData,
                    fileID: expectedFileID
                )
            if let fileName = target.kind.nativeFileName {
                fileDataForPersistence.documentData = try ExcalidrawDocumentAppStatePersistence.documentData(
                    fileDataForPersistence.documentData,
                    settingNativeFileName: fileName
                )
            }
        }

        return fileDataForPersistence
    }
}
