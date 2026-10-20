//
//  ExcalidrawCore+MediaHelpers.swift
//  ExcalidrawZ
//
//  Created by Codex on 2026/06/18.
//

import CoreData
import Foundation

extension ExcalidrawCore {
    /// Get Excalidraw Indexed DB Data
    func getExcalidrawStore() async throws -> [ExcalidrawFile.ResourceFile] {
        let raw = try await webView.callAsyncJavaScript(
            "return await window.excalidrawZHelper.getAllMedias();",
            arguments: [:],
            contentWorld: .page
        )
        guard let dict = raw as? [String: Any], let filesAny = dict["files"] else {
            struct GetAllMediasFailed: Error {}
            throw GetAllMediasFailed()
        }
        let data = try JSONSerialization.data(withJSONObject: filesAny)
        return try JSONDecoder().decode([ExcalidrawFile.ResourceFile].self, from: data)
    }

    /// Insert media files to IndexedDB
    @MainActor
    func insertMediaFiles(_ files: [ExcalidrawFile.ResourceFile]) async throws {
        guard !files.isEmpty else { return }

        let jsonStringified = try files.jsonStringified()
        _ = try await webView.callAsyncJavaScript(
            """
            return await window.excalidrawZHelper.insertMedias(filesJSON);
            """,
            arguments: [
                "filesJSON": jsonStringified,
            ],
            contentWorld: .page
        )

        var loadedIDs = loadedMediaItemIDSnapshot()
        loadedIDs.formUnion(files.map(\.id))
        updateLoadedMediaItemIDs(loadedIDs)
    }

    /// Inject all MediaItems from CoreData to IndexedDB
    /// This method fetches all MediaItems and injects them into the WebView's IndexedDB
    /// Most work (fetching, loading files) runs on background threads for better performance
    /// - Returns: The count of injected MediaItems
    func injectAllMediaItems() async throws -> Int {
        try await injectMediaItems(onlyIDs: nil)
    }

    /// - Parameter onlyIDs: When set, inject just these media items and add
    ///   them to the loaded set; otherwise inject everything and replace it.
    private func injectMediaItems(onlyIDs: Set<String>?) async throws -> Int {
        let hasParent = await MainActor.run {
            parent != nil
        }
        guard hasParent else {
            return 0
        }

        let isReady = await MainActor.run {
            !isNavigating && (hasInjectIndexedDBData || isDocumentLoaded)
        }

        guard isReady else {
            logger.warning("WebView not ready for MediaItem injection, skipping")
            return 0
        }

        let context = PersistenceController.shared.newTaskContext()
        // Object IDs and media IDs only; each item's data is read by its own task.
        let (mediaObjectIDs, mediaIDs): ([NSManagedObjectID], Set<String>) = try await context.perform {
            let predicate = onlyIDs.map { NSPredicate(format: "id IN %@", Array($0)) }
            let objectIDRequest = NSFetchRequest<NSManagedObjectID>(entityName: "MediaItem")
            objectIDRequest.resultType = .managedObjectIDResultType
            objectIDRequest.predicate = predicate
            let idRequest = NSFetchRequest<NSDictionary>(entityName: "MediaItem")
            idRequest.resultType = .dictionaryResultType
            idRequest.propertiesToFetch = ["id"]
            idRequest.predicate = predicate
            return (
                try context.fetch(objectIDRequest),
                Set(try context.fetch(idRequest).compactMap { $0["id"] as? String })
            )
        }

        let mediaFiles = await withTaskGroup(of: ExcalidrawFile.ResourceFile?.self) { group in
            var files: [ExcalidrawFile.ResourceFile] = []

            for id in mediaObjectIDs {
                group.addTask {
                    // Background contexts may only be used on their own queue.
                    let mediaItem = await context.perform { context.object(with: id) as? MediaItem }
                    guard let mediaItem else { return nil }
                    return try? await ExcalidrawFile.ResourceFile(mediaItem: mediaItem)
                }
            }

            for await resourceFile in group {
                if let resourceFile = resourceFile {
                    files.append(resourceFile)
                }
            }

            return files
        }

        try await self.insertMediaFiles(mediaFiles)
        await MainActor.run {
            if onlyIDs == nil {
                self.updateLoadedMediaItemIDs(mediaIDs)
            } else {
                self.updateLoadedMediaItemIDs(self.loadedMediaItemIDSnapshot().union(mediaIDs))
            }
            self.hasInjectIndexedDBData = true
        }

        return mediaFiles.count
    }

    /// Check if MediaItems have changed and re-inject if needed
    /// This is the public method that should be called when MediaItem changes are detected
    public func refreshMediaItemsIfNeeded() async throws {
        let (currentIDs, loadedIDs) = try await MainActor.run {
            let context = PersistenceController.shared.container.viewContext
            // IDs only: a managed-object fetch ignores `propertiesToFetch` and
            // faulted in every image's inline data on the main thread.
            let fetchRequest = NSFetchRequest<NSDictionary>(entityName: "MediaItem")
            fetchRequest.resultType = .dictionaryResultType
            fetchRequest.propertiesToFetch = ["id"]
            let currentIDs = Set(try context.fetch(fetchRequest).compactMap { $0["id"] as? String })

            return (currentIDs, self.loadedMediaItemIDSnapshot())
        }

        // Re-injecting the whole library for one new image read and
        // base64-encoded every image again; send only the ones the editor lacks.
        let missingIDs = currentIDs.subtracting(loadedIDs)
        if !missingIDs.isEmpty {
            _ = try await injectMediaItems(onlyIDs: missingIDs)
        }
        if !loadedIDs.isSubset(of: currentIDs) {
            await MainActor.run {
                self.updateLoadedMediaItemIDs(self.loadedMediaItemIDSnapshot().intersection(currentIDs))
            }
        }
    }

    @MainActor
    @discardableResult
    public func loadImageToExcalidrawCanvas(imageData: Data, type: String) async throws -> LoadImageResult? {
        // Passed as base64: printing the bytes as a JS array literal built a
        // script several times the image size.
        let raw = try await webView.callAsyncJavaScript(
            """
            const binary = atob(base64);
            const bytes = new Uint8Array(binary.length);
            for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
            return await window.excalidrawZHelper.loadImageBuffer(bytes, type);
            """,
            arguments: ["base64": imageData.base64EncodedString(), "type": type],
            contentWorld: .page
        )
        let result = LoadImageResult(fromJS: raw)
        documentSyncController.scheduleProgrammaticMutationCommit(reason: "loadImageToExcalidrawCanvas")
        return result
    }
}
