//
//  LocalFileContextMenu.swift
//  ExcalidrawZ
//
//  Created by Chocoford on 8/7/25.
//

import SwiftUI
import CoreData
import Logging
import ChocofordUI

private let localFileContextMenuLogger = Logger(label: "LocalFileContextMenu")

struct LocalFileMenuProvider: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.alertToast) private var alertToast
    @EnvironmentObject private var fileState: FileState
    @EnvironmentObject var localFolderState: LocalFolderState

    var file: URL?
    var content: (Triggers) -> AnyView

    init<Content: View>(
        file: URL?,
        content: @escaping (Triggers) -> Content
    ) {
        self.file = file
        self.content = { AnyView(content($0)) }
    }
    
    
    struct Triggers {
        var onToggleRename: () -> Void
    }
    
    @State private var isRenameSheetPresented = false
    
    var triggers: Triggers {
        Triggers {
            isRenameSheetPresented.toggle()
        }
    }
    
    private var files: Set<URL> {
        if let file {
            if fileState.selectedLocalFiles.contains(file) {
                return fileState.selectedLocalFiles
            }
            return [file]
        }
        return fileState.selectedLocalFiles
    }
    
    private var firstFile: URL? {
        files.first
    }

    var body: some View {
        content(triggers)
            .modifier(
                RenameSheetViewModifier(
                    isPresented: $isRenameSheetPresented,
                    name: firstFile?.deletingPathExtension().lastPathComponent ?? ""
                ) { newName in
                    guard let file = firstFile else { return }
                    Task { await renameFile(file: file, newName: newName) }
                }
            )
    }

    @MainActor
    private func renameFile(file: URL, newName: String) async {
        let newURL = file.deletingLastPathComponent()
            .appendingPathComponent(
                newName,
                conformingTo: .excalidrawFile
            )
        guard !newURL.hasSameFileSystemPath(as: file) else { return }

        // An open editor session is bound to the file URL. Close it first so
        // pending edits are saved to the old path, then reopen it at the new
        // path; otherwise the editor keeps the old name and autosave
        // recreates the old file.
        let wasOpen = fileState.currentActiveFile == .localFile(file)
        if wasOpen, !(await fileState.requestActiveFileChange(nil)) {
            return
        }

        do {
            guard try moveFile(file, to: newURL) else {
                if wasOpen { _ = await fileState.requestActiveFileChange(.localFile(file)) }
                return
            }
        } catch {
            if wasOpen { _ = await fileState.requestActiveFileChange(.localFile(file)) }
            alertToast(error)
            return
        }

        if fileState.selectedLocalFiles.contains(file) {
            fileState.selectedLocalFiles.remove(file)
            fileState.selectedLocalFiles.insert(newURL)
        }
        if wasOpen {
            _ = await fileState.requestActiveFileChange(.localFile(newURL))
        }
    }

    /// Returns false when the file's linked folder is unknown.
    private func moveFile(_ file: URL, to newURL: URL) throws -> Bool {
        // find folder
        let fetchRequest = NSFetchRequest<LocalFolder>(entityName: "LocalFolder")
        fetchRequest.predicate = NSPredicate(format: "filePath == %@", file.deletingLastPathComponent().filePath)
        guard let folder = try viewContext.fetch(fetchRequest).first else { return false }

        try folder.withSecurityScopedURL { _ in
            try FileManager.default.moveItem(at: file, to: newURL)

            // Update local file ID mapping
            ExcalidrawFile.moveLocalFileID(from: file, to: newURL)

            // Also update checkpoints
            updateCheckpoints(oldURL: file, newURL: newURL)
            rebindAIConversations(oldURL: file, newURL: newURL)

            localFolderState.itemRenamedPublisher.send(newURL.filePath)
        }
        return true
    }

    private func rebindAIConversations(oldURL: URL, newURL: URL) {
        Task.detached {
            do {
                let oldScope = AIConversationFileScope(kind: .localFile, id: oldURL.absoluteString)
                let newScope = AIConversationFileScope(kind: .localFile, id: newURL.absoluteString)
                try await PersistenceController.shared.aiConversationRepository.rebindConversations(
                    from: oldScope,
                    to: newScope
                )
                await AIChatPreferences.shared.rebindFileAccessOverride(
                    from: oldScope,
                    to: newScope
                )
            } catch {
                localFileContextMenuLogger.warning("Failed to rebind AI conversations for renamed local file: \(error)")
            }
        }
    }
    
    private func updateCheckpoints(oldURL: URL, newURL: URL) {
        let context = PersistenceController.shared.container.newBackgroundContext()
        Task.detached {
            do {
                try await context.perform {
                    let fetchRequest = NSFetchRequest<LocalFileCheckpoint>(entityName: "LocalFileCheckpoint")
                    fetchRequest.predicate = NSPredicate(format: "url = %@", oldURL as NSURL)
                    let checkpoints = try context.fetch(fetchRequest)
                    checkpoints.forEach {
                        $0.url = newURL
                    }
                    try context.save()
                }
            } catch {
                await alertToast(error)
            }
        }
    }
}

struct LocalFileRowContextMenuModifier: ViewModifier {
    var file: URL
    
    func body(content: Content) -> some View {
        LocalFileMenuProvider(file: file) { triggers in
            content
                .contextMenu {
                    LocalFileRowMenuItems(file: file) {
                        triggers.onToggleRename()
                    }
                    .labelStyle(.titleAndIcon)
                }
        }
    }
}

struct LocalFileMenu: View {
    var file: URL?
    var label: AnyView
    
    init<Label: View>(
        file: URL?,
        @ViewBuilder label: () -> Label
    ) {
        self.file = file
        self.label = AnyView(label())
    }
    
    var body: some View {
        LocalFileMenuProvider(file: file) { triggers in
            FileActionSubmenu {
                LocalFileRowMenuItems(file: file) {
                    triggers.onToggleRename()
                }
            } label: {
                label
            }
        }
    }
}

struct LocalFileRowMenuItems: View {
    @Environment(\.dismissFlatFileMenu) private var dismissFlatFileMenu

    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.containerHorizontalSizeClass) private var containerHorizontalSizeClass
    @Environment(\.alertToast) private var alertToast
#if os(iOS)
    @Environment(\.editMode) private var editMode
#endif
    
    @EnvironmentObject var fileState: FileState
    @EnvironmentObject var localFolderState: LocalFolderState

    var file: URL?
    var onToggleRename: () -> Void

    
    @FetchRequest(
        sortDescriptors: [SortDescriptor(\.filePath, order: .forward)],
        predicate: NSPredicate(format: "parent = nil"),
        animation: .default
    )
    private var topLevelLocalFolders: FetchedResults<LocalFolder>
    
    private var files: Set<URL> {
        if let file {
            if fileState.selectedLocalFiles.contains(file) {
                return fileState.selectedLocalFiles
            }
            return [file]
        }
        return fileState.selectedLocalFiles
    }
    
    private var isSingleFile: Bool {
        files.count == 1
    }
    
    private var firstFile: URL? {
        files.first
    }

    private var sourceLocalFolder: LocalFolder? {
        let parentPaths = Set(
            files.map {
                $0.deletingLastPathComponent().standardizedFileURL.filePath
            }
        )
        guard parentPaths.count == 1, let parentPath = parentPaths.first else {
            return nil
        }

        let request = NSFetchRequest<LocalFolder>(entityName: "LocalFolder")
        request.predicate = NSPredicate(format: "filePath == %@", parentPath)
        request.fetchLimit = 1
        return try? viewContext.fetch(request).first
    }
    
    var body: some View {
        if containerHorizontalSizeClass != .compact {
            var isInEditMode: Bool {
#if os(iOS)
                editMode?.wrappedValue == .active
#else
                false
#endif
            }
            
            // Open
            if !isInEditMode,
               let file = firstFile,
               fileState.currentActiveFile != .localFile(file) {
                FileActionButton {
                    if let firstFile {
                        fileState.setActiveFile(.localFile(firstFile))
                    }
                } label: {
                    Label(
                        .localizable(.generalButtonOpen),
                        systemSymbol: .arrowUpRightSquare
                    )
                }
                .disabled(!isSingleFile)
            }
            // Download / Remove download
            if let firstFile, isSingleFile {
                FileStatusProvider(file: .localFile(firstFile)) { fileStatus in
                    if fileStatus?.iCloudStatus == .conflict {
                        
                    } else if fileStatus?.iCloudStatus == .downloaded {
                        AsyncButton {
                            dismissFlatFileMenu()
                            try await FileCoordinator.shared.evictLocalCopy(of: firstFile)
                        } label: {
                            Label(
                                "Remove download",
                                systemSymbol: .xmarkCircle
                            )
                        }
                    } else if fileStatus?.iCloudStatus == .outdated {
                        AsyncButton {
                            dismissFlatFileMenu()
                            try await FileCoordinator.shared.downloadFile(url: firstFile)
                        } label: {
                            Label(
                                "Download",
                                systemSymbol: .icloudAndArrowDown
                            )
                        }
                    }
                    
                }
            }
        }
        
        // Rename
        FileActionButton {
            onToggleRename()
        } label: {
            Label(
                .localizable(.sidebarFileRowContextMenuRename),
                systemSymbol: .squareAndPencil
            )
        }
        .disabled(!isSingleFile)


        FileActionButton {
            duplicateFile()
        } label: {
            Label {
                if #available(macOS 13.0, iOS 16.0, *), files.count > 1 {
                    Text(
                        localizable: .sidebarFileRowContextMenuDuplicateFiles(files.count)
                    )
                } else {
                    Text(localizable: .sidebarFileRowContextMenuDuplicate)
                }
            } icon: {
                Image(systemSymbol: .docOnDoc)
            }
        }

        moveLocalFileMenu()
        
#if os(macOS)
        FileActionButton {
#if canImport(AppKit)
            NSPasteboard.general.clearContents()
            if let firstFile {
                NSPasteboard.general.setString(firstFile.filePath, forType: .string)
            }
#elseif canImport(UIKit)
            if let firstFile {
                UIPasteboard.general.setObjects([firstFile.filePath])
            }
#endif
        } label: {
            Label(.localizable(.sidebarLocalFileRowContextMenuCopyPath), systemSymbol: .arrowRightDocOnClipboard)
        }
        .disabled(!isSingleFile)

        FileActionButton {
            let filesToReveal = Array(files)
            guard !filesToReveal.isEmpty else { return }
            NSWorkspace.shared.activateFileViewerSelecting(filesToReveal)
        } label: {
            Label(
                .localizable(
                    .generalButtonRevealInFinder
                ),
                systemSymbol: .docViewfinder
            )
        }
#endif
        Divider()
        
        // Delete
        FileActionButton {
            moveToTrash()
        } label: {
            Label {
                if #available(macOS 13.0, iOS 16.0, *), files.count > 1 {
                    Text(
                        localizable: .generalButtonMoveFilesToTrash(files.count)
                    )
                } else {
                    Text(localizable: .generalButtonMoveToTrash)
                }
            } icon: {
                Image(systemSymbol: .trash)
            }
            .foregroundStyle(.red)
        }
    }
    
    
    @ViewBuilder
    private func moveLocalFileMenu() -> some View {
        if !files.isEmpty {
            let sourceFolder = sourceLocalFolder
            FileActionSubmenu {
                ForEach(topLevelLocalFolders) { folder in
                    MoveToGroupMenu(
                        destination: folder,
                        sourceGroup: sourceFolder,
                        childrenSortKey: \LocalFolder.filePath,
                        allowSubgroups: true
                    ) { targetFolderID in
                        moveLocalFile(to: targetFolderID)
                    }
                }
            } label: {
                
                Label {
                    if #available(macOS 13.0, iOS 16.0, *) {
                        if files.count > 1 {
                            Text(
                                localizable: .generalMoveFilesTo(
                                    files.count
                                )
                            )
                        } else {
                            Text(localizable: .generalMoveTo)
                        }
                    } else {
                        Text(localizable: .generalMoveTo)
                    }
                } icon: {
                    Image(systemSymbol: .trayAndArrowUp)
                }
            }
        }
    }
    
    
    private func duplicateFile() {
        let filesToDuplicate = Array(files)

        Task {
            do {
                var fileToBeActive: URL? = nil
                for sourceFile in filesToDuplicate {
                    // Scope access to each file's own linked folder: the
                    // menu also appears outside a local-folder view (Home,
                    // Recent), where no active group grants access.
                    let newURL = try await LocalFolder.withSecurityScopedAccessToContainingFolder(
                        for: sourceFile
                    ) { () async throws -> URL? in
                        let file = try ExcalidrawFile(contentsOf: sourceFile)
                        guard let data = file.content else { return nil }
                        // Check collisions where the copy is written (the source's own
                        // folder), not the linked root: otherwise a copy of a file in a
                        // sub-folder could overwrite an existing "Name-1" there.
                        let destinationFolder = sourceFile.deletingLastPathComponent()
                        let newURL = Self.availableDuplicateURL(
                            for: sourceFile.deletingPathExtension().lastPathComponent,
                            in: destinationFolder
                        )
                        // Use FileCoordinator for safe atomic write
                        try await FileCoordinator.shared.coordinatedWrite(url: newURL, data: data)
                        return newURL
                    }
                    if filesToDuplicate.count == 1 {
                        fileToBeActive = newURL
                    }
                }

                await MainActor.run { [fileToBeActive] in
                    if let fileToBeActive,
                       let sourceFile = filesToDuplicate.first,
                       fileState.currentActiveFile == .localFile(sourceFile) {
                        fileState.setActiveFile(.localFile(fileToBeActive))
                    }
                }
            } catch {
                await MainActor.run {
                    alertToast(error)
                }
            }
        }
    }

    /// "Name" -> "Name-1", "Name-1" -> "Name-2"; a dash inside the name
    /// ("my-plan") is kept instead of growing "my-plan-1-1".
    private static func availableDuplicateURL(for baseName: String, in folder: URL) -> URL {
        var stem = baseName
        var index = 1
        if let dash = baseName.lastIndex(of: "-"),
           let number = Int(baseName[baseName.index(after: dash)...]) {
            stem = String(baseName[..<dash])
            index = number + 1
        }
        while true {
            let candidate = folder.appendingPathComponent("\(stem)-\(index)", conformingTo: .excalidrawFile)
            if !FileManager.default.fileExists(at: candidate) {
                return candidate
            }
            index += 1
        }
    }

    private func moveLocalFile(to targetFolderID: NSManagedObjectID) {
        let context = PersistenceController.shared.container.newBackgroundContext()
        let filesToMove = Array(files)
        let currentActiveFile: URL? = if case .localFile(let currentFile) = fileState.currentActiveFile {
            currentFile
        } else { nil }

        Task {
            do {
                let mapping = try await LocalFileUtils.moveLocalFiles(filesToMove, to: targetFolderID, context: context)

                if let currentActiveFile, let newURL = mapping[currentActiveFile] {
                    await MainActor.run {
                        if let targetFolder = viewContext.object(with: targetFolderID) as? LocalFolder {
                            fileState.currentActiveGroup = .localFolder(targetFolder)
                        }
                        fileState.setActiveFile(.localFile(newURL))
                    }
                }
                localFolderState.publishMovedItems(mapping)
            } catch {
                await MainActor.run {
                    alertToast(error)
                }
            }
        }
    }
    
    private func moveToTrash() {
        let filesToDelete = Array(files)

        Task {
            // Close an open editor first: its boundary save would otherwise write
            // the drawing back to its old path after it was trashed.
            if case .localFile(let activeURL) = fileState.currentActiveFile,
               filesToDelete.contains(where: { $0.hasSameFileSystemPath(as: activeURL) }),
               !(await fileState.requestActiveFileChange(nil)) {
                return
            }
            do {
                for file in filesToDelete {
                    try await LocalFolder.withSecurityScopedAccessToContainingFolder(for: file) {
                        _ = try await FileCoordinator.shared.coordinatedTrash(url: file)
                    }
                    let scope = AIConversationFileScope(
                        kind: .localFile,
                        id: file.absoluteString
                    )
                    do {
                        try await PersistenceController.shared.aiConversationRepository
                            .deleteConversations(
                                forFileScope: scope
                            )
                        AIChatPreferences.shared.deleteFileAccessOverride(for: scope)
                    } catch {
                        localFileContextMenuLogger.warning("Failed to delete AI conversations for local file \(file): \(error)")
                    }
                    await MainActor.run {
                        localFolderState.itemRemovedPublisher.send(file.filePath)
                    }
                }

                await MainActor.run {
                    if let currentActiveFile = {
                        if case .localFile(let file) = fileState.currentActiveFile {
                            return file
                        }
                        return nil
                    }(), filesToDelete.contains(currentActiveFile) {
                        fileState.setActiveFile(nil)
                    }
                }
            } catch {
                await MainActor.run {
                    alertToast(error)
                }
            }
        }
    }
}
