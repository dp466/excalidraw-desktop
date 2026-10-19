//
//  LocalFilesProvider.swift
//  ExcalidrawZ
//
//  Created by Chocoford on 12/22/25.
//

import SwiftUI
import CoreData
import Logging

import ChocofordUI

private let localFilesProviderLogger = Logger(label: "LocalFilesProvider")

struct LocalFilesProvider<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.alertToast) private var alertToast
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    @EnvironmentObject private var fileState: FileState
    @EnvironmentObject private var localFolderState: LocalFolderState
    
    var folder: LocalFolder
    var sortField: ExcalidrawFileSortField
    var content: (_ files: [URL], _ updateFlag: [URL : Date]) -> Content
    
    init(
        folder: LocalFolder,
        sortField: ExcalidrawFileSortField,
        @ViewBuilder content: @escaping (_ files: [URL], _ updateFlag: [URL : Date]) -> Content
    ) {
        self.folder = folder
        self.sortField = sortField
        self.content = content
    }
    
    static func withSibling(
        file: URL,
        sortField: ExcalidrawFileSortField,
        @ViewBuilder content: @escaping (_ files: [URL], _ updateFlag: [URL : Date]) -> Content
    ) -> Self? {
        let fetchRequest = NSFetchRequest<LocalFolder>(entityName: "LocalFolder")
        fetchRequest.predicate = NSPredicate(format: "filePath == %@", file.deletingLastPathComponent().filePath)
        fetchRequest.fetchLimit = 1
        
        guard let folder = (try? PersistenceController.shared.container.viewContext.fetch(fetchRequest))?.first else {
            return nil
        }
        
        return LocalFilesProvider(
            folder: folder,
            sortField: sortField,
            content: content
        )
    }
    
    
    @State private var files: [URL] = []
    @State private var updateFlags: [URL : Date] = [:]
    @State private var sortValues: [URL: ExcalidrawFileSortProvider.Values] = [:]
    @State private var didLoadInitialCache = false
    @State private var refreshGeneration = 0
    @State private var refreshTask: Task<Void, Never>?
    
#if canImport(AppKit)
    @State private var window: NSWindow?
#elseif canImport(UIKit)
    @State private var window: UIWindow?
#endif
    
    var body: some View {
        content(files, updateFlags)
            .bindAppWindow($window)
            .onAppear {
                loadCachedFilesIfNeeded()
            }
            .task(id: folderContentsLoadID) {
                getFolderContents()
            }
            .onDisappear {
                refreshTask?.cancel()
            }
#if os(macOS)
            .onReceive(
                NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            ) { notification in
                if let window = notification.object as? NSWindow,
                   window == self.window {
                    DispatchQueue.main.async {
                        guard fileState.currentActiveGroup == .localFolder(folder) else { return }
                        getFolderContents()
                        if fileState.currentActiveFile == nil || {
                            if case .localFile(let localFile) = fileState.currentActiveFile {
                                return !isDirectChildOfCurrentFolder(localFile)
                            } else {
                                return true
                            }
                        }() {
                            fileState.setActiveFile(nil)
                        }
                    }
                }
            }
#elseif os(iOS)
            .watch(value: scenePhase) { newValue in
                if newValue == .active {
                    getFolderContents()
                }
            }
#endif
            .watch(value: sortField) { _ in
                getFolderContents()
            }
            .onReceive(localFolderState.itemCreatedPublisher) { path in
                handleItemCreated(path: path)
            }
            .onReceive(localFolderState.itemRemovedPublisher) { path in
                handleItemRemoved(path: path)
            }
            .onReceive(localFolderState.itemUpdatedPublisher) { path in
                handleItemUpdated(path: path)
            }
            .onReceive(localFolderState.itemRenamedPublisher) { path in
                handleItemRenamed(path: path)
            }
            .onReceive(localFolderState.itemsMovedPublisher) { mapping in
                handleItemsMoved(mapping)
            }
            .onReceive(localFolderState.refreshFilesPublisher) { _ in
                getFolderContents(debounceNanoseconds: 150_000_000)
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .localFolderAvailabilityDidChange)
            ) { notification in
                guard let folderID = notification.object as? NSManagedObjectID,
                      folderID == folder.objectID else { return }
                getFolderContents()
            }
    }

    private var folderContentsLoadID: String {
        folder.url?.filePath ?? folder.objectID.uriRepresentation().absoluteString
    }

    private var folderCacheKey: String {
        folder.url?.standardizedFileURL.path ?? folder.objectID.uriRepresentation().absoluteString
    }

    private func loadCachedFilesIfNeeded() {
        guard !didLoadInitialCache else { return }
        didLoadInitialCache = true

        guard files.isEmpty,
              let cachedFiles = LocalFilesProviderCache.files(for: folderCacheKey) else {
            return
        }

        self.files = cachedFiles
        sortFiles(field: sortField)
        self.updateFlags = cachedFiles.map { [$0: Date()] }.merged()
    }
    
    private func getFolderContents(debounceNanoseconds: UInt64 = 0) {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let requestedFolderID = folderContentsLoadID
        let requestedCacheKey = folderCacheKey
        let sortFieldRawValue = sortField.rawValue
        let activeURL: URL?
        if case .localFile(let url) = fileState.currentActiveFile {
            activeURL = url
        } else {
            activeURL = nil
        }
        let folderObjectID = folder.objectID

        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            do {
                if debounceNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: debounceNanoseconds)
                }
                let refreshStartedAt = Date()
                let context = PersistenceController.shared.newTaskContext()
                let snapshot = try await context.perform { () throws -> LocalFolderContentsLoader.Snapshot? in
                    try Task.checkCancellation()
                    guard let backgroundFolder = try context.existingObject(
                        with: folderObjectID
                    ) as? LocalFolder else { return nil }
                    return try backgroundFolder.withSecurityScopedURL { folderURL in
                        try LocalFolderContentsLoader.load(
                            at: folderURL,
                            activeURL: activeURL,
                            sortFieldRawValue: sortFieldRawValue
                        )
                    }
                }
                try Task.checkCancellation()
                guard generation == refreshGeneration,
                      requestedFolderID == folderContentsLoadID,
                      let snapshot else { return }

                localFilesProviderLogger.debug(
                    "Refreshed \(snapshot.files.count) local files in \(Date().timeIntervalSince(refreshStartedAt)) seconds"
                )

                sortValues = snapshot.metadata.mapValues { metadata in
                    ExcalidrawFileSortProvider.Values(
                        name: metadata.name,
                        updatedAt: metadata.updatedAt,
                        createdAt: metadata.createdAt
                    )
                }
                withAnimation {
                    files = snapshot.files
                    LocalFilesProviderCache.setFiles(snapshot.files, for: requestedCacheKey)
                }
                let refreshedAt = Date()
                updateFlags = Dictionary(snapshot.files.map { ($0, refreshedAt) }, uniquingKeysWith: { first, _ in first })
            } catch is CancellationError {
                return
            } catch {
                guard generation == refreshGeneration else { return }
                alertToast(error)
            }
        }
    }
    
    private func sortFiles(field: ExcalidrawFileSortField) {
        files = ExcalidrawFileSortProvider.sorted(files, by: field) { file in
            sortValues[file] ?? ExcalidrawFileSortProvider.Values(
                name: file.deletingPathExtension().lastPathComponent,
                updatedAt: nil,
                createdAt: nil
            )
        }
    }

    private func handleItemCreated(path: String) {
        let fileURL = URL(fileURLWithPath: path)
        guard LocalFolderContentsLoader.isSupportedFile(fileURL),
              isDirectChildOfCurrentFolder(fileURL) else { return }
        getFolderContents(debounceNanoseconds: 150_000_000)
    }

    private func isDirectChildOfCurrentFolder(_ fileURL: URL) -> Bool {
        guard let folderPath = folder.filePath else { return false }
        let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        return fileURL.deletingLastPathComponent().hasSameFileSystemPath(as: folderURL)
    }
    
    private func handleItemRemoved(path: String) {
        refreshGeneration &+= 1
        refreshTask?.cancel()
        if case .localFile(let file) = fileState.currentActiveFile, file.filePath == path {
            let index = files.firstIndex(where: {$0.filePath == path}) ?? -1
            if index <= 0 {
                if files.count <= 1 {
                    fileState.setActiveFile(nil)
                } else {
                    fileState.setActiveFile(.localFile(files[1]))
                }
            } else {
                fileState.setActiveFile(.localFile(files[0]))
            }
        }
        files.removeAll(where: { $0.filePath == path })
        LocalFilesProviderCache.setFiles(files, for: folderCacheKey)
        deleteAIConversations(forLocalFileAtPath: path)
    }

    private func deleteAIConversations(forLocalFileAtPath path: String) {
        let url = URL(fileURLWithPath: path)
        Task.detached {
            let scope = AIConversationFileScope(
                kind: .localFile,
                id: url.absoluteString
            )
            do {
                try await PersistenceController.shared.aiConversationRepository
                    .deleteConversations(
                        forFileScope: scope
                    )
                await AIChatPreferences.shared.deleteFileAccessOverride(for: scope)
            } catch {
                localFilesProviderLogger.warning("Failed to delete AI conversations for removed local file \(path): \(error)")
            }
        }
    }
    
    private func handleItemUpdated(path: String) {
        guard let file = self.files.first(where: {$0.filePath == path}) else { return }
        self.updateFlags[file] = Date()
        getFolderContents(debounceNanoseconds: 150_000_000)
    }
    
    private func handleItemRenamed(path _: String) {
        getFolderContents(debounceNanoseconds: 150_000_000)
    }

    private func handleItemsMoved(_ mapping: [URL: URL]) {
        guard let folderURL = folder.url?.standardizedFileURL else { return }
        let shouldRefresh = mapping.contains { source, destination in
            folderURL == source.deletingLastPathComponent().standardizedFileURL
                || folderURL == destination.deletingLastPathComponent().standardizedFileURL
        }
        guard shouldRefresh else {
            return
        }
        getFolderContents(debounceNanoseconds: 150_000_000)
    }
}

@MainActor
private enum LocalFilesProviderCache {
    private static var filesByFolderPath: [String: [URL]] = [:]

    static func files(for folderPath: String) -> [URL]? {
        filesByFolderPath[folderPath]
    }

    static func setFiles(_ files: [URL], for folderPath: String) {
        filesByFolderPath[folderPath] = files
    }
}
