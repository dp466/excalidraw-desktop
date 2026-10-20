import CoreData
import Foundation
import ImageIO
import SwiftUI
#if os(macOS)
import AppKit
#endif

enum MCPDocumentCommandError: LocalizedError {
    case invalid(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message), .unavailable(let message): message
        }
    }
}

/// Shared validation and raw JSON transformations. Deliberately avoids the
/// typed element model so future Excalidraw fields survive library round trips.
enum MCPDocumentCommandValidation {
    static func name(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."),
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              name.utf8.count <= 220 else {
            throw MCPDocumentCommandError.invalid("name must be a non-hidden filename component, without path separators or control characters (maximum 220 UTF-8 bytes).")
        }
        return name
    }

    static func contained(_ url: URL, in root: URL) -> Bool {
        // Foundation can leave intermediate symlinks unresolved when the final
        // filename does not exist yet. Resolve the nearest existing ancestor
        // first, then append the nonexistent suffix for creation checks.
        func resolvedPath(_ url: URL) -> String {
            var ancestor = url.standardizedFileURL
            var suffix: [String] = []
            while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
                suffix.append(ancestor.lastPathComponent)
                ancestor.deleteLastPathComponent()
            }
            var resolved = ancestor.resolvingSymlinksInPath()
            for component in suffix.reversed() { resolved.appendPathComponent(component) }
            return resolved.standardizedFileURL.path
        }
        let path = resolvedPath(url)
        let rootPath = resolvedPath(root)
        return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    static func elements(_ value: MCPJSONValue) throws -> [MCPJSONValue] {
        guard let elements = value.arrayValue, !elements.isEmpty, elements.count <= 10_000 else {
            throw MCPDocumentCommandError.invalid("elements must contain between 1 and 10,000 element objects.")
        }
        var ids = Set<String>()
        for element in elements {
            guard let object = element.objectValue,
                  let id = object["id"]?.stringValue, !id.isEmpty,
                  ids.insert(id).inserted,
                  let type = object["type"]?.stringValue, !type.isEmpty else {
                throw MCPDocumentCommandError.invalid("Every library element needs a unique id and a type.")
            }
            for key in ["x", "y", "width", "height"] {
                guard let number = object[key]?.numberValue, number.isFinite else {
                    throw MCPDocumentCommandError.invalid("Library element \(id) requires finite \(key).")
                }
            }
        }
        return elements
    }

    static func insertion(_ value: MCPJSONValue, x: Double, y: Double) throws -> [MCPJSONValue] {
        guard x.isFinite, y.isFinite else {
            throw MCPDocumentCommandError.invalid("Library insertion coordinates must be finite.")
        }
        let elements = try elements(value)
        let idMap = Dictionary(uniqueKeysWithValues: elements.map { ($0["id"]!.stringValue!, UUID().uuidString) })
        let groups = Set(elements.flatMap { $0["groupIds"]?.arrayValue?.compactMap(\.stringValue) ?? [] })
        let groupMap = Dictionary(uniqueKeysWithValues: groups.map { ($0, UUID().uuidString) })
        let minX = elements.map { min($0["x"]!.numberValue!, $0["x"]!.numberValue! + $0["width"]!.numberValue!) }.min() ?? 0
        let minY = elements.map { min($0["y"]!.numberValue!, $0["y"]!.numberValue! + $0["height"]!.numberValue!) }.min() ?? 0
        return elements.map { element in
            var object = element.objectValue!
            object["id"] = .string(idMap[object["id"]!.stringValue!]!)
            object["x"] = .number(object["x"]!.numberValue! + x - minX)
            object["y"] = .number(object["y"]!.numberValue! + y - minY)
            for key in ["frameId", "containerId"] {
                if let old = object[key]?.stringValue {
                    object[key] = idMap[old].map(MCPJSONValue.string) ?? .null
                }
            }
            if let values = object["boundElements"]?.arrayValue {
                object["boundElements"] = .array(values.compactMap { bound in
                    guard var entry = bound.objectValue, let old = entry["id"]?.stringValue,
                          let id = idMap[old] else { return nil }
                    entry["id"] = .string(id)
                    return .object(entry)
                })
            }
            for key in ["startBinding", "endBinding"] {
                if var binding = object[key]?.objectValue, let old = binding["elementId"]?.stringValue {
                    if let id = idMap[old] { binding["elementId"] = .string(id); object[key] = .object(binding) }
                    else { object[key] = .null }
                }
            }
            if let groupIDs = object["groupIds"]?.arrayValue {
                object["groupIds"] = .array(groupIDs.compactMap { $0.stringValue.flatMap { groupMap[$0] }.map(MCPJSONValue.string) })
            }
            object["isDeleted"] = .bool(false)
            return .object(object)
        }
    }

    static func sceneDiff(before: MCPJSONValue, after: MCPJSONValue) -> MCPJSONValue {
        func indexed(_ scene: MCPJSONValue) -> [String: MCPJSONValue] {
            var result: [String: MCPJSONValue] = [:]
            for element in scene["elements"]?.arrayValue ?? [] where element["isDeleted"] != .bool(true) {
                if let id = element["id"]?.stringValue { result[id] = element }
            }
            return result
        }
        let old = indexed(before), new = indexed(after)
        let oldIDs = Set(old.keys), newIDs = Set(new.keys)
        return .object([
            "added_ids": .array(newIDs.subtracting(oldIDs).sorted().map(MCPJSONValue.string)),
            "removed_ids": .array(oldIDs.subtracting(newIDs).sorted().map(MCPJSONValue.string)),
            "changed_ids": .array(oldIDs.intersection(newIDs).filter { old[$0] != new[$0] }.sorted().map(MCPJSONValue.string)),
            "app_state_changed": .bool(before["appState"] != after["appState"]),
            "assets_changed": .bool(before["files"] != after["files"])
        ])
    }

    static func remappingAssets(in elements: [MCPJSONValue], files: [String: MCPJSONValue]) throws -> (elements: [MCPJSONValue], files: [String: MCPJSONValue]) {
        let remapping = Dictionary(uniqueKeysWithValues: files.keys.map { ($0, UUID().uuidString) })
        let resources = try files.reduce(into: [String: MCPJSONValue]()) { result, entry in
            guard var resource = entry.value.objectValue, let id = remapping[entry.key] else {
                throw MCPDocumentCommandError.invalid("Image resources must be objects.")
            }
            resource["id"] = .string(id)
            result[id] = .object(resource)
        }
        let remapped = try elements.map { element -> MCPJSONValue in
            guard var value = element.objectValue else { return element }
            if value["type"] == .string("image") {
                guard let oldID = value["fileId"]?.stringValue, let id = remapping[oldID] else {
                    throw MCPDocumentCommandError.invalid("Image elements require complete embedded assets.")
                }
                value["fileId"] = .string(id)
            }
            return .object(value)
        }
        return (remapped, resources)
    }
}

@MainActor
private final class MCPDocumentCommandState {
    static let shared = MCPDocumentCommandState()
    var presentationDocumentID: String?
}

@MainActor
extension ExcalidrawMCPAppBridge {
    static let fullDocumentActions = ["discover", "search", "create", "open", "save", "rename", "duplicate", "move", "trash", "restore", "create_folder"]
    static let fullLibraryActions = ["list", "search", "get", "create", "update", "delete", "import", "export", "preview", "insert"]
    static let fullPresentationActions = ["list", "configure", "start", "stop", "go_to"]

    func ensureMCPApprovedLocalDocument(documentID: String) throws {
        guard let context = mcpContext else { throw BridgeError.appContextUnavailable }
        let (url, _) = try mcpApprovedLocalDocument(documentID, context: context)
        guard AIChatPreferences.shared.allowsFileAccess(for: .localFile(url)) else { throw BridgeError.currentFileAccessDenied }
    }

    func fullDocumentCommand(arguments: [String: MCPJSONValue]) async throws -> MCPJSONValue {
        var arguments = arguments
        if arguments["document_id"] == nil { arguments["document_id"] = arguments["file_url"] }
        if ["move", "duplicate"].contains(arguments["action"]?.stringValue ?? "") {
            if let value = arguments["destination_group_id"] { arguments["group_id"] = value }
            if let value = arguments["destination_folder_id"] { arguments["local_folder_id"] = value }
        }
        guard arguments["group_id"] == nil || arguments["local_folder_id"] == nil else { throw MCPDocumentCommandError.invalid("Choose one destination: group_id or local_folder_id.") }
        let action = try mcpRequiredString(arguments, "action")
        guard let state = mcpFileState, let appContext = mcpContext else { throw BridgeError.appContextUnavailable }
        let context = mcpIsolatedMetadataContext(appContext)
        switch action {
        case "discover", "search":
            return try await mcpDiscoverDocuments(arguments: arguments)
        case "create":
            try await mcpFlushCurrentDocument()
            let name = try MCPDocumentCommandValidation.name(mcpRequiredString(arguments, "name"))
            if let folderID = arguments["local_folder_id"]?.stringValue {
                return try await mcpOpenedDocumentResult(optimizedCreateLocalFile(name: name, localFolderID: folderID))
            }
            return try await mcpOpenedDocumentResult(optimizedCreateFile(name: name, groupID: arguments["group_id"]?.stringValue))
        case "open":
            let id = try mcpRequiredString(arguments, "document_id")
            if let active = state.currentActiveFile, active.id == id {
                // Reopening the captured target is also the recovery path for
                // a rejected editor load. It does not switch documents, so do
                // not require a snapshot from a canvas that never loaded it.
                guard state.aiChatSession == nil else { throw BridgeError.aiGenerationInProgress }
                switch active {
                case .file(let file):
                    guard AIChatPreferences.shared.allowsFileAccess(for: active),
                          try await LockedContentAIGuard.canToolAccess(fileObjectID: file.objectID) else { throw BridgeError.currentFileAccessDenied }
                case .localFile: try ensureMCPApprovedLocalDocument(documentID: id)
                default: throw BridgeError.unsupportedActiveFile("Full MCP opens app-managed and approved linked local documents.")
                }
                if let coordinator = state.excalidrawWebCoordinator,
                   coordinator.documentSyncController.currentLoadedFileID != id,
                   !coordinator.documentSyncController.hasPendingFileLoad,
                   let scene = coordinator.parent?.file, scene.id == id {
                    _ = await coordinator.documentSyncController.load(scene, force: true)
                }
                let current = await optimizedAppContext()["currentFile"] ?? .object([:])
                return try await mcpOpenedDocumentResult(current, persistence: "unchanged")
            }
            try await mcpFlushCurrentDocument()
            if UUID(uuidString: id) != nil { return try await mcpOpenedDocumentResult(optimizedOpenFile(fileID: id)) }
            _ = try mcpApprovedLocalDocument(id, context: context)
            return try await mcpOpenedDocumentResult(optimizedOpenLocalFile(fileURL: id))
        case "save":
            return try await saveMCPDocument(documentID: mcpRequiredString(arguments, "document_id"))
        case "create_folder":
            let name = try MCPDocumentCommandValidation.name(mcpRequiredString(arguments, "name"))
            if let folderID = arguments["local_folder_id"]?.stringValue {
                let folder = try mcpFolder(folderID, context: context)
                let childURL = try mcpWithScopedURL(folder) { root in
                    let url = root.appendingPathComponent(name, isDirectory: true)
                    guard MCPDocumentCommandValidation.contained(url, in: root) else { throw BridgeError.currentFileAccessDenied }
                    guard !FileManager.default.fileExists(atPath: url.path) else { throw MCPDocumentCommandError.invalid("A folder or file with that name already exists.") }
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                    return url
                }
                try folder.refreshChildren(context: context, recursively: false)
                let request = NSFetchRequest<LocalFolder>(entityName: "LocalFolder")
                request.predicate = NSPredicate(format: "url == %@", childURL as NSURL)
                let child = try context.fetch(request).first
                return .object(["local_folder_id": child.map { .string($0.objectID.uriRepresentation().absoluteString) } ?? .null, "path": .string(childURL.path), "name": .string(name)])
            }
            let parent = try mcpGroup(arguments["group_id"]?.stringValue, context: context)
            let group = Group(name: name, context: context)
            group.parent = parent
            group.groupType = .normal
            try context.save()
            return .object(["group_id": group.id.map { .string($0.uuidString) } ?? .null, "name": .string(name)])
        case "restore" where arguments["trash_id"] != nil:
            return try await mcpRestoreLocalDocument(arguments: arguments, context: context)
        case "rename", "duplicate", "move", "trash", "restore":
            let id = try mcpRequiredString(arguments, "document_id")
            if action != "restore", state.currentActiveFile?.id == id {
                let (_, coordinator) = try await requireMCPDocument(documentID: id, requiresMutation: true)
                _ = try await mcpEnsureRevision(arguments: arguments, documentID: id, coordinator: coordinator)
            }
            if UUID(uuidString: id) != nil {
                return try await mcpMutateManagedDocument(id: id, action: action, arguments: arguments, state: state, context: context)
            }
            return try await mcpMutateLocalDocument(id: id, action: action, arguments: arguments, state: state, context: context)
        default:
            throw MCPDocumentCommandError.invalid("Unsupported document action: \(action).")
        }
    }

    /// Uses the same captured-target flush gate as file switching and app
    /// termination; unlike the external-mutation convenience API, failure is
    /// propagated and a caller never reports persistence based on canvas state.
    func saveMCPDocument(documentID: String) async throws -> MCPJSONValue {
        let (state, _) = try await requireMCPDocument(documentID: documentID, requiresMutation: true)
        guard await state.flushPendingCanvasSnapshotBeforeTermination(),
              state.currentActiveFile?.id == documentID else {
            throw MCPDocumentCommandError.unavailable("The canvas snapshot could not be saved to the captured document target. The document remains open; retry save before moving or closing it.")
        }
        return .object(["document_id": .string(documentID), "persistence": .string("saved"), "saved_at": .string(Self.iso8601String(from: Date()))])
    }

    private func mcpFlushCurrentDocument() async throws {
        guard let state = mcpFileState, state.currentActiveFile != nil else { return }
        // Saving the previously visible document is internal navigation work;
        // it does not grant the caller read access to protected contents.
        guard await state.flushPendingCanvasSnapshotBeforeTermination() else {
            throw MCPDocumentCommandError.unavailable("The current document could not be saved before switching. It remains open.")
        }
    }

    private func mcpOpenedDocumentResult(_ value: MCPJSONValue, persistence: String = "saved") async throws -> MCPJSONValue {
        var result = value.objectValue ?? [:]
        guard let state = mcpFileState, let id = state.currentActiveFile?.id else { throw BridgeError.createdFileUnavailable }
        result["document_id"] = .string(id)
        result["persistence"] = .string(persistence)
        if let coordinator = state.excalidrawWebCoordinator,
           try await coordinator.documentSyncController.waitUntilFileIsLoaded(id, timeout: 20) {
            let (_, coordinator) = try await requireMCPDocument(documentID: id, requiresMutation: false)
            result["revision"] = try await coordinator.performDiagramCommand(["action": .string("inspect"), "document_id": .string(id), "limit": .number(1)])["revision"] ?? .null
            result["ready"] = .bool(true)
        } else { result["ready"] = .bool(false); result["revision"] = .null }
        result["windows"] = mcpOpenWindows()
        result["load_status"] = .string(result["ready"] == .bool(true) ? "ready" : state.excalidrawWebCoordinator?.documentSyncController.hasPendingFileLoad == true ? "pending" : "failed")
        return .object(result)
    }

    private func mcpDiscoverDocuments(arguments: [String: MCPJSONValue]) async throws -> MCPJSONValue {
        guard let state = mcpFileState, let context = mcpContext else { throw BridgeError.appContextUnavailable }
        let query = arguments["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let includeTrash = arguments["include_trash"] == .bool(true)
        let offset = try mcpPageInteger(arguments, "offset", default: 0, maximum: 1_000_000)
        let limit = try mcpPageInteger(arguments, "limit", default: 100, maximum: 200)
        let request = NSFetchRequest<File>(entityName: "File")
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false), NSSortDescriptor(key: "name", ascending: true)]
        var predicates: [NSPredicate] = []
        if !includeTrash { predicates.append(NSCompoundPredicate(notPredicateWithSubpredicate: File.trashedPredicate)) }
        if !query.isEmpty { predicates.append(NSPredicate(format: "name CONTAINS[cd] %@", query)) }
        if let groupID = arguments["group_id"]?.stringValue { predicates.append(NSPredicate(format: "group == %@", try mcpGroup(groupID, context: context))) }
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        var entries: [MCPJSONValue] = []
        for file in try context.fetch(request) {
            guard let id = file.id, AIChatPreferences.shared.allowsFileAccess(for: .file(file)),
                  (try await LockedContentAIGuard.canToolAccess(fileObjectID: file.objectID)) else { continue }
            entries.append(.object(["document_id": .string(id.uuidString), "kind": .string("managed"), "name": .string(file.name ?? "Untitled"), "group_id": file.group?.id.map { .string($0.uuidString) } ?? .null, "in_trash": .bool(file.inTrash || file.group?.groupType == .trash), "updated_at": file.updatedAt.map { .string(Self.iso8601String(from: $0)) } ?? .null, "is_open": .bool(state.activeFiles.compactMap { $0?.id }.contains(id.uuidString)), "can_read": .bool(true), "can_write": .bool(!file.inTrash && file.group?.groupType != .trash)]))
        }
        if arguments["group_id"] == nil {
            let folderRequest = NSFetchRequest<LocalFolder>(entityName: "LocalFolder")
            folderRequest.sortDescriptors = [NSSortDescriptor(key: "filePath", ascending: true)]
            let folders = if let id = arguments["local_folder_id"]?.stringValue { [try mcpFolder(id, context: context)] } else { try context.fetch(folderRequest).filter { $0.parent == nil } }
            var seen = Set<String>()
            for folder in folders {
                let urls = try folder.getFiles(deep: arguments["deep"] != .bool(false))
                for url in urls {
                    guard url.pathExtension.lowercased() == "excalidraw", seen.insert(url.standardizedFileURL.path).inserted,
                          query.isEmpty || url.lastPathComponent.localizedStandardContains(query),
                          AIChatPreferences.shared.allowsFileAccess(for: .localFile(url)) else { continue }
                    _ = try mcpApprovedLocalDocument(url.absoluteString, context: context)
                    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    entries.append(.object(["document_id": .string(url.standardizedFileURL.absoluteString), "kind": .string("local"), "name": .string(url.lastPathComponent), "local_folder_id": .string(folder.objectID.uriRepresentation().absoluteString), "path": .string(url.path), "updated_at": values?.contentModificationDate.map { .string(Self.iso8601String(from: $0)) } ?? .null, "size_bytes": values?.fileSize.map { .number(Double($0)) } ?? .null, "in_trash": .bool(false), "is_open": .bool(state.activeFiles.compactMap { $0?.id }.contains(url.absoluteString)), "can_read": .bool(true), "can_write": .bool(true)]))
                }
                if includeTrash { entries.append(contentsOf: try mcpLocalTrashEntries(folder: folder, query: query)) }
            }
        }
        let slice = Array(entries.dropFirst(offset).prefix(limit))
        return .object(["documents": .array(slice), "total": .number(Double(entries.count)), "returned": .number(Double(slice.count)), "next_offset": offset + slice.count < entries.count ? .number(Double(offset + slice.count)) : .null, "groups": try await optimizedListGroups(), "local_folders": try await optimizedListLocalFolders(), "omitted_protected_documents": .bool(true)])
    }

    private func mcpMutateManagedDocument(id: String, action: String, arguments: [String: MCPJSONValue], state: FileState, context: NSManagedObjectContext) async throws -> MCPJSONValue {
        let file = try mcpManagedFile(id, context: context)
        guard AIChatPreferences.shared.allowsFileAccess(for: .file(file)),
              try await LockedContentAIGuard.canToolAccess(fileObjectID: file.objectID) else { throw BridgeError.currentFileAccessDenied }
        let isTrash = file.inTrash || file.group?.groupType == .trash
        guard action == "restore" || !isTrash else { throw MCPDocumentCommandError.invalid("Restore the document before editing or duplicating it.") }
        if action != "restore", state.currentActiveFile?.id == id { _ = try await saveMCPDocument(documentID: id) }
        switch action {
        case "rename":
            file.name = try MCPDocumentCommandValidation.name(mcpRequiredString(arguments, "name"))
            try context.save()
        case "duplicate":
            let name = try MCPDocumentCommandValidation.name(arguments["name"]?.stringValue ?? (file.name ?? "Untitled") + " copy")
            let content = try await mcpCompleteManagedContent(file)
            if let folderID = arguments["local_folder_id"]?.stringValue {
                let folder = try mcpFolder(folderID, context: context)
                let url = try await folder.withSecurityScopedURL { root in
                    let url = try self.mcpUniqueFileURL(name: name, root: root)
                    try await FileCoordinator.shared.coordinatedWrite(url: url, data: content)
                    if let presentation = file.presentationData {
                        do { try await FileCoordinator.shared.coordinatedWrite(url: self.mcpPresentationSidecar(url), data: presentation) }
                        catch { try? FileManager.default.removeItem(at: url); throw error }
                    }
                    return url
                }
                return .object(["document_id": .string(url.absoluteString), "kind": .string("local"), "persistence": .string("saved")])
            }
            let group = try mcpGroup(arguments["group_id"]?.stringValue ?? file.group?.id?.uuidString, context: context)
            let objectID = try await mcpCreateManagedCopy(name: name, content: content, group: group)
            if let duplicate = try context.existingObject(with: objectID) as? File {
                duplicate.presentationData = file.presentationData
                try context.save()
                return .object(["document_id": duplicate.id.map { .string($0.uuidString) } ?? .null, "kind": .string("managed"), "persistence": .string("saved")])
            }
            throw BridgeError.createdFileUnavailable
        case "move":
            if arguments["local_folder_id"] != nil {
                let copy = try await mcpMutateManagedDocument(id: id, action: "duplicate", arguments: arguments, state: state, context: context)
                do { _ = try await mcpMutateManagedDocument(id: id, action: "trash", arguments: arguments, state: state, context: context) }
                catch {
                    if let destination = copy["document_id"]?.stringValue, let url = URL(string: destination) {
                        let folder = try mcpFolder(mcpRequiredString(arguments, "local_folder_id"), context: context)
                        try? mcpWithScopedURL(folder) { _ in try FileManager.default.removeItem(at: url) }
                    }
                    throw error
                }
                var result = copy.objectValue ?? [:]
                result["previous_document_id"] = .string(id); result["action"] = .string("move"); result["original_recoverable"] = .bool(true)
                return .object(result)
            }
            file.group = try mcpGroup(mcpRequiredString(arguments, "group_id"), context: context)
            try context.save()
            if state.currentActiveFile?.id == id, let group = file.group {
                let displayGroup = (try? mcpContext?.existingObject(with: group.objectID) as? Group) ?? group
                state.currentActiveGroup = .group(displayGroup)
            }
        case "trash":
            if state.currentActiveFile?.id == id {
                guard await state.requestActiveFileChange(nil) else { throw MCPDocumentCommandError.unavailable("The active document could not be closed safely.") }
            }
            // Never pass an already trashed file to repository.delete: that
            // API intentionally interprets it as permanent deletion.
            try await PersistenceController.shared.fileRepository.delete(fileObjectIDs: [file.objectID], forcePermanently: false)
        case "restore":
            guard isTrash else { throw MCPDocumentCommandError.invalid("The document is not in Trash.") }
            file.inTrash = false
            file.deletedAt = nil
            if let destination = arguments["group_id"]?.stringValue { file.group = try mcpGroup(destination, context: context) }
            else if file.group == nil || file.group?.groupType == .trash { file.group = try mcpGroup(nil, context: context) }
            try context.save()
        default: throw MCPDocumentCommandError.invalid("Unsupported managed document action.")
        }
        if let uuid = file.id { await PersistenceController.shared.spotlightIndexingService.indexFile(id: uuid) }
        return .object(["document_id": .string(id), "action": .string(action), "persistence": .string("saved")])
    }

    private func mcpMutateLocalDocument(id: String, action: String, arguments: [String: MCPJSONValue], state: FileState, context: NSManagedObjectContext) async throws -> MCPJSONValue {
        let (source, sourceFolder) = try mcpApprovedLocalDocument(id, context: context)
        guard AIChatPreferences.shared.allowsFileAccess(for: .localFile(source)) else { throw BridgeError.currentFileAccessDenied }
        if state.currentActiveFile?.id == id { _ = try await saveMCPDocument(documentID: id) }
        let name = try MCPDocumentCommandValidation.name(arguments["name"]?.stringValue ?? source.deletingPathExtension().lastPathComponent + (action == "duplicate" ? " copy" : ""))
        switch action {
        case "duplicate":
            let data = try mcpWithScopedURL(sourceFolder) { _ in try Data(contentsOf: source) }
            if let groupID = arguments["group_id"]?.stringValue {
                let group = try mcpGroup(groupID, context: context)
                let objectID = try await mcpCreateManagedCopy(name: name, content: data, group: group)
                guard let file = try context.existingObject(with: objectID) as? File, let uuid = file.id else { throw BridgeError.createdFileUnavailable }
                let presentation = try mcpWithScopedURL(sourceFolder) { root -> Data? in
                    let sidecar = mcpPresentationSidecar(source)
                    guard MCPDocumentCommandValidation.contained(sidecar, in: root) else { throw BridgeError.currentFileAccessDenied }
                    return FileManager.default.fileExists(atPath: sidecar.path) ? try Data(contentsOf: sidecar) : nil
                }
                file.presentationData = presentation
                try context.save()
                return .object(["document_id": .string(uuid.uuidString), "kind": .string("managed"), "persistence": .string("saved")])
            }
            let folder = try arguments["local_folder_id"]?.stringValue.map { try mcpFolder($0, context: context) } ?? sourceFolder
            let destination = try await folder.withSecurityScopedURL { root in
                let url = try self.mcpUniqueFileURL(name: name, root: root)
                try await FileCoordinator.shared.coordinatedWrite(url: url, data: data)
                do {
                    try self.mcpWithScopedURL(sourceFolder) { sourceRoot in
                        let sidecar = self.mcpPresentationSidecar(source)
                        guard MCPDocumentCommandValidation.contained(sidecar, in: sourceRoot) else { throw BridgeError.currentFileAccessDenied }
                        if FileManager.default.fileExists(atPath: sidecar.path) { try FileManager.default.copyItem(at: sidecar, to: self.mcpPresentationSidecar(url)) }
                    }
                } catch { try? FileManager.default.removeItem(at: url); throw error }
                return url
            }
            return .object(["document_id": .string(destination.absoluteString), "kind": .string("local"), "persistence": .string("saved")])
        case "rename", "move":
            if action == "move", arguments["group_id"] != nil {
                let copy = try await mcpMutateLocalDocument(id: id, action: "duplicate", arguments: arguments, state: state, context: context)
                do { _ = try await mcpMutateLocalDocument(id: id, action: "trash", arguments: arguments, state: state, context: context) }
                catch {
                    if let destination = copy["document_id"]?.stringValue, let copiedFile = try? mcpManagedFile(destination, context: context) {
                        try? await PersistenceController.shared.fileRepository.delete(fileObjectIDs: [copiedFile.objectID], forcePermanently: true)
                    }
                    throw error
                }
                var result = copy.objectValue ?? [:]
                result["previous_document_id"] = .string(id); result["action"] = .string("move"); result["original_recoverable"] = .bool(true)
                return .object(result)
            }
            let folder = try arguments["local_folder_id"]?.stringValue.map { try mcpFolder($0, context: context) } ?? sourceFolder
            let wasOpen = state.currentActiveFile?.id == id
            if wasOpen, !(await state.requestActiveFileChange(nil)) { throw MCPDocumentCommandError.unavailable("The active document could not be closed safely.") }
            let destination: URL
            do {
                destination = try mcpWithScopedURL(sourceFolder) { _ in
                    try mcpWithScopedURL(folder) { root in
                        let base = name.hasSuffix(".excalidraw") ? String(name.dropLast(11)) : name
                        let destination = root.appendingPathComponent(base).appendingPathExtension("excalidraw")
                        guard MCPDocumentCommandValidation.contained(destination, in: root) else { throw BridgeError.currentFileAccessDenied }
                        if destination == source { return source }
                        guard !FileManager.default.fileExists(atPath: destination.path) else { throw MCPDocumentCommandError.invalid("The destination already exists.") }
                        try FileManager.default.moveItem(at: source, to: destination)
                        try mcpMoveSidecar(from: source, to: destination)
                        return destination
                    }
                }
            } catch {
                if wasOpen { _ = await state.requestActiveFileChange(.localFile(source)) }
                throw error
            }
            do { try mcpRebaseLocalHistory(from: source, to: destination, context: context) }
            catch {
                context.rollback()
                do {
                    try mcpWithScopedURL(folder) { _ in
                        try mcpWithScopedURL(sourceFolder) { _ in
                            if source != destination {
                                try FileManager.default.moveItem(at: destination, to: source)
                                try mcpMoveSidecar(from: destination, to: source)
                            }
                        }
                    }
                } catch {
                    throw ExcalidrawMCPCommandError(code: "move_recovery_required", message: "The document moved, but history could not be saved and its original location could not be restored. Inspect both returned locations before retrying.", details: .object(["original_document_id": .string(id), "destination_document_id": .string(destination.absoluteString)]))
                }
                if wasOpen { _ = await state.requestActiveFileChange(.localFile(source)) }
                throw error
            }
            if wasOpen {
                let displayFolder = (try? mcpContext?.existingObject(with: folder.objectID) as? LocalFolder) ?? folder
                state.currentActiveGroup = .localFolder(displayFolder)
                _ = await state.requestActiveFileChange(.localFile(destination))
            }
            return .object(["document_id": .string(destination.absoluteString), "previous_document_id": .string(id), "persistence": .string("saved")])
        case "trash":
            if state.currentActiveFile?.id == id, !(await state.requestActiveFileChange(nil)) { throw MCPDocumentCommandError.unavailable("The active document could not be closed safely.") }
            let trashID = UUID().uuidString
            try mcpWithScopedURL(sourceFolder) { root in
                let trash = root.appendingPathComponent(".excalidraw-mcp-trash", isDirectory: true)
                guard MCPDocumentCommandValidation.contained(trash, in: root) else { throw BridgeError.currentFileAccessDenied }
                try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
                let payload = trash.appendingPathComponent(trashID).appendingPathExtension("excalidraw")
                let manifest = MCPJSONValue.object(["trash_id": .string(trashID), "document_id": .string(id), "name": .string(source.lastPathComponent), "trashed_at": .string(Self.iso8601String(from: Date()))])
                try manifest.mcpJSONData().write(to: trash.appendingPathComponent(trashID).appendingPathExtension("json"), options: .atomic)
                do { try FileManager.default.moveItem(at: source, to: payload); try mcpMoveSidecar(from: source, to: payload) }
                catch { try? FileManager.default.removeItem(at: trash.appendingPathComponent(trashID).appendingPathExtension("json")); throw error }
            }
            return .object(["document_id": .string(id), "trash_id": .string(trashID), "local_folder_id": .string(sourceFolder.objectID.uriRepresentation().absoluteString), "persistence": .string("saved"), "recoverable": .bool(true)])
        case "restore": throw MCPDocumentCommandError.invalid("Local restore requires trash_id and local_folder_id returned by trash or discover(include_trash:true).")
        default: throw MCPDocumentCommandError.invalid("Unsupported local document action.")
        }
    }

    private func mcpRestoreLocalDocument(arguments: [String: MCPJSONValue], context: NSManagedObjectContext) async throws -> MCPJSONValue {
        let token = try mcpRequiredString(arguments, "trash_id")
        guard UUID(uuidString: token) != nil else { throw MCPDocumentCommandError.invalid("trash_id must be a UUID.") }
        let folder = try mcpFolder(mcpRequiredString(arguments, "local_folder_id"), context: context)
        let restored = try mcpWithScopedURL(folder) { root in
            let trash = root.appendingPathComponent(".excalidraw-mcp-trash", isDirectory: true)
            guard MCPDocumentCommandValidation.contained(trash, in: root) else { throw BridgeError.currentFileAccessDenied }
            let manifestURL = trash.appendingPathComponent(token).appendingPathExtension("json")
            let manifest = try MCPJSONValue.parse(from: Data(contentsOf: manifestURL))
            guard let original = manifest["document_id"]?.stringValue, let destination = URL(string: original),
                  destination.isFileURL, MCPDocumentCommandValidation.contained(destination, in: root),
                  AIChatPreferences.shared.allowsFileAccess(for: .localFile(destination)) else { throw BridgeError.currentFileAccessDenied }
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw MCPDocumentCommandError.invalid("The original path is occupied. Move that file before restoring this document.") }
            let payload = trash.appendingPathComponent(token).appendingPathExtension("excalidraw")
            guard MCPDocumentCommandValidation.contained(payload, in: root) else { throw BridgeError.currentFileAccessDenied }
            try FileManager.default.moveItem(at: payload, to: destination)
            try mcpMoveSidecar(from: payload, to: destination)
            try FileManager.default.removeItem(at: manifestURL)
            return destination
        }
        return .object(["document_id": .string(restored.absoluteString), "persistence": .string("saved"), "restored": .bool(true)])
    }

    private func mcpLocalTrashEntries(folder: LocalFolder, query: String) throws -> [MCPJSONValue] {
        try mcpWithScopedURL(folder) { root in
            let trash = root.appendingPathComponent(".excalidraw-mcp-trash", isDirectory: true)
            guard MCPDocumentCommandValidation.contained(trash, in: root), FileManager.default.fileExists(atPath: trash.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.compactMap { url in
                guard MCPDocumentCommandValidation.contained(url, in: root), let value = try? MCPJSONValue.parse(from: Data(contentsOf: url)),
                      var entry = value.objectValue, let original = entry["document_id"]?.stringValue, let originalURL = URL(string: original),
                      MCPDocumentCommandValidation.contained(originalURL, in: root), AIChatPreferences.shared.allowsFileAccess(for: .localFile(originalURL)),
                      query.isEmpty || (entry["name"]?.stringValue ?? "").localizedStandardContains(query) else { return nil }
                entry["in_trash"] = .bool(true)
                entry["kind"] = .string("local")
                entry["local_folder_id"] = .string(folder.objectID.uriRepresentation().absoluteString)
                return .object(entry)
            }
        }
    }

    private func mcpCompleteManagedContent(_ file: File) async throws -> Data {
        guard var object = try MCPJSONValue.parse(from: await file.loadContent()).objectValue, object["elements"]?.arrayValue != nil else {
            throw BridgeError.invalidGeneratedFile("The managed document is not a complete Excalidraw scene.")
        }
        var files = object["files"]?.objectValue ?? [:]
        for media in file.medias?.allObjects as? [MediaItem] ?? [] {
            let resource = try await ExcalidrawFile.ResourceFile(mediaItem: media)
            let canonical = try MCPJSONValue.parse(from: JSONEncoder().encode(resource)).objectValue ?? [:]
            files[resource.id] = .object((files[resource.id]?.objectValue ?? [:]).merging(canonical) { _, new in new })
        }
        if let context = file.managedObjectContext {
            let missing = (object["elements"]?.arrayValue ?? []).filter { $0["type"]?.stringValue == "image" && $0["fileId"]?.stringValue.map { files[$0] == nil } == true }
            for (id, resource) in try await mcpLibraryAssets(missing, context: context) { files[id] = resource }
        }
        object["files"] = .object(files)
        return try MCPJSONValue.object(object).mcpJSONData()
    }

    private func mcpCreateManagedCopy(name: String, content: Data, group: Group) async throws -> NSManagedObjectID {
        guard var object = try MCPJSONValue.parse(from: content).objectValue,
              let elements = object["elements"]?.arrayValue else { throw BridgeError.invalidGeneratedFile("The source is not an Excalidraw scene.") }
        let files = object["files"]?.objectValue ?? [:]
        for element in elements where element["type"]?.stringValue == "image" {
            guard let id = element["fileId"]?.stringValue, files[id] != nil else { throw BridgeError.invalidGeneratedFile("The source contains an image without a complete embedded asset.") }
        }
        let remapped = try MCPDocumentCommandValidation.remappingAssets(in: elements, files: files)
        let resources = try remapped.files.values.map { value in
            try JSONDecoder().decode(ExcalidrawFile.ResourceFile.self, from: value.mcpJSONData())
        }
        object["elements"] = .array(remapped.elements)
        // Keep the complete envelope as a fallback until independent media
        // records have been written. IDs are fresh so deleting the source
        // cannot remove assets shared by this copy.
        object["files"] = .object(remapped.files)
        let copiedContent = try MCPJSONValue.object(object).mcpJSONData()
        let objectID = try await PersistenceController.shared.fileRepository.createFile(name: name, content: copiedContent, groupObjectID: group.objectID)
        do {
            _ = try await PersistenceController.shared.mediaItemRepository.createMediaItems(resources: resources, fileObjectID: objectID)
            return objectID
        } catch {
            try? await PersistenceController.shared.fileRepository.delete(fileObjectIDs: [objectID], forcePermanently: true)
            throw error
        }
    }

    private func mcpApprovedLocalDocument(_ id: String, context: NSManagedObjectContext) throws -> (URL, LocalFolder) {
        guard let url = URL(string: id), url.isFileURL, url.pathExtension.lowercased() == "excalidraw" else { throw BridgeError.localFileNotFound(id) }
        let canonical = url.standardizedFileURL
        guard let candidate = try LocalFolder.deepestFolder(containingLocalFileAt: canonical, in: context) else { throw BridgeError.currentFileAccessDenied }
        let folder = try mcpFolder(candidate.objectID.uriRepresentation().absoluteString, context: context)
        try mcpWithScopedURL(folder) { root in
            guard MCPDocumentCommandValidation.contained(canonical, in: root) else { throw BridgeError.currentFileAccessDenied }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &directory), !directory.boolValue else { throw BridgeError.localFileNotFound(id) }
        }
        return (canonical, folder)
    }

    private func mcpManagedFile(_ id: String, context: NSManagedObjectContext) throws -> File {
        guard let uuid = UUID(uuidString: id) else { throw BridgeError.fileNotFound(id) }
        let request = NSFetchRequest<File>(entityName: "File")
        request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
        request.fetchLimit = 1
        guard let file = try context.fetch(request).first else { throw BridgeError.fileNotFound(id) }
        return file
    }

    private func mcpGroup(_ id: String?, context: NSManagedObjectContext) throws -> Group {
        let group: Group
        if let id {
            guard let uuid = UUID(uuidString: id) else { throw BridgeError.groupNotFound(id) }
            let request = NSFetchRequest<Group>(entityName: "Group")
            request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
            request.fetchLimit = 1
            guard let found = try context.fetch(request).first else { throw BridgeError.groupNotFound(id) }
            group = found
        } else {
            guard let found = try PersistenceController.shared.getDefaultGroup(context: context) else { throw BridgeError.targetGroupUnavailable }
            group = found
        }
        guard group.groupType != .trash else { throw BridgeError.unsupportedTargetGroup("Trash cannot receive new MCP documents or folders.") }
        return group
    }

    private func mcpFolder(_ id: String, context: NSManagedObjectContext) throws -> LocalFolder {
        guard let uri = URL(string: id), let objectID = context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: uri),
              let folder = try context.existingObject(with: objectID) as? LocalFolder else { throw BridgeError.localFolderNotFound(id) }
        // Resolve and test the saved bookmark before any path operation.
        try mcpWithScopedURL(folder) { root in
            var ancestor = folder
            var seen = Set<NSManagedObjectID>()
            while let parent = ancestor.parent {
                guard seen.insert(ancestor.objectID).inserted else { throw BridgeError.currentFileAccessDenied }
                ancestor = parent
            }
            guard let approvedRoot = try ancestor.scopedURL,
                  MCPDocumentCommandValidation.contained(root, in: approvedRoot) else { throw BridgeError.currentFileAccessDenied }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else { throw BridgeError.localFolderNotFound(id) }
        }
        return folder
    }

    private func mcpUniqueFileURL(name: String, root: URL) throws -> URL {
        let base = name.hasSuffix(".excalidraw") ? String(name.dropLast(11)) : name
        var url = root.appendingPathComponent(base).appendingPathExtension("excalidraw")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) { url = root.appendingPathComponent("\(base) \(suffix)").appendingPathExtension("excalidraw"); suffix += 1 }
        guard MCPDocumentCommandValidation.contained(url, in: root) else { throw BridgeError.currentFileAccessDenied }
        return url
    }

    private func mcpPresentationSidecar(_ url: URL) -> URL { url.appendingPathExtension("presentation.json") }

    private func mcpMoveSidecar(from source: URL, to destination: URL) throws {
        let sourceSidecar = mcpPresentationSidecar(source)
        if FileManager.default.fileExists(atPath: sourceSidecar.path) {
            do { try FileManager.default.moveItem(at: sourceSidecar, to: mcpPresentationSidecar(destination)) }
            catch { try? FileManager.default.moveItem(at: destination, to: source); throw error }
        }
    }

    private func mcpRebaseLocalHistory(from source: URL, to destination: URL, context: NSManagedObjectContext) throws {
        let request = NSFetchRequest<LocalFileCheckpoint>(entityName: "LocalFileCheckpoint")
        request.predicate = NSPredicate(format: "url == %@", source as NSURL)
        for checkpoint in try context.fetch(request) { checkpoint.url = destination }
        try context.save()
        ExcalidrawFile.moveLocalFileID(from: source, to: destination)
    }

    private func mcpRequiredString(_ arguments: [String: MCPJSONValue], _ key: String) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MCPDocumentCommandError.invalid("Missing required nonempty string: \(key).") }
        return value
    }

    private func mcpWithScopedURL<T>(_ folder: LocalFolder, _ operation: (URL) throws -> T) throws -> T {
        let scoped: ((URL) throws -> T) throws -> T = folder.withSecurityScopedURL(actions:)
        return try scoped(operation)
    }

    private func mcpIsolatedMetadataContext(_ appContext: NSManagedObjectContext) -> NSManagedObjectContext {
        // A command must neither commit unrelated edits in the UI context nor
        // leave failed metadata changes queued for a subsequent UI save.
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = appContext.persistentStoreCoordinator
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.automaticallyMergesChangesFromParent = true
        return context
    }

    private func mcpPageInteger(_ arguments: [String: MCPJSONValue], _ key: String, default fallback: Int, maximum: Int) throws -> Int {
        guard let value = arguments[key] else { return fallback }
        guard let number = value.numberValue, number.isFinite, number.rounded() == number, number >= (key == "offset" ? 0 : 1), number <= Double(maximum) else { throw MCPDocumentCommandError.invalid("\(key) must be an integer within the supported bounds.") }
        return Int(number)
    }

    private func mcpEnsureRevision(arguments: [String: MCPJSONValue], documentID: String, coordinator: ExcalidrawCanvasView.Coordinator) async throws -> MCPJSONValue {
        let expected = try mcpRequiredString(arguments, "expected_revision")
        let inspection = try await coordinator.performDiagramCommand(["action": .string("inspect"), "document_id": .string(documentID), "limit": .number(1)])
        guard inspection["revision"] == .string(expected) else {
            throw ExcalidrawMCPCommandError(code: "revision_conflict", message: "The diagram changed. Read it again before changing presentation settings or creating a checkpoint.", details: inspection["revision"])
        }
        return inspection["revision"] ?? .null
    }

    func fullLibraryCommand(arguments: [String: MCPJSONValue]) async throws -> MCPJSONValue {
        let action = try mcpRequiredString(arguments, "action")
        guard mcpFileState != nil, let appContext = mcpContext else { throw BridgeError.appContextUnavailable }
        let context = mcpIsolatedMetadataContext(appContext)
        switch action {
        case "list", "search":
            let query = arguments["query"]?.stringValue ?? ""
            let limit = try mcpPageInteger(arguments, "limit", default: 100, maximum: 200)
            let offset = try mcpPageInteger(arguments, "offset", default: 0, maximum: 1_000_000)
            let request = NSFetchRequest<Library>(entityName: "Library")
            request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
            let libraries = if let id = arguments["library_id"]?.stringValue { [try mcpLibrary(id, context: context)] } else { try context.fetch(request) }
            var rows: [MCPJSONValue] = []
            for library in libraries {
                let items = mcpLibraryItems(library)
                if arguments["library_id"] == nil && query.isEmpty {
                    rows.append(.object(["library_id": library.id.map { .string($0.uuidString) } ?? .null, "name": .string(library.name ?? "Untitled"), "item_count": .number(Double(items.count))]))
                } else {
                    for item in items where query.isEmpty || (item.name ?? "").localizedStandardContains(query) || (library.name ?? "").localizedStandardContains(query) {
                        rows.append(try mcpLibraryItemValue(item, includeElements: arguments["include_elements"] == .bool(true)))
                    }
                }
            }
            let slice = Array(rows.dropFirst(offset).prefix(limit))
            return .object(["items": .array(slice), "total": .number(Double(rows.count)), "returned": .number(Double(slice.count)), "next_offset": offset + slice.count < rows.count ? .number(Double(offset + slice.count)) : .null])
        case "get":
            let library = try mcpLibrary(mcpRequiredString(arguments, "library_id"), context: context)
            if let itemID = arguments["item_id"]?.stringValue {
                var value = try mcpLibraryItemValue(mcpLibraryItem(itemID, library: library), includeElements: true).objectValue!
                value["files"] = .object(try await mcpLibraryAssets(value["elements"]?.arrayValue ?? [], context: context, libraryID: library.id))
                return .object(value)
            }
            return try await mcpLibraryValue(library)
        case "create":
            let name = try MCPDocumentCommandValidation.name(mcpRequiredString(arguments, "name"))
            if let libraryID = arguments["library_id"]?.stringValue {
                let library = try mcpLibrary(libraryID, context: context)
                let elements = try MCPDocumentCommandValidation.elements(arguments["elements"] ?? .null)
                let itemID = arguments["item_id"]?.stringValue ?? UUID().uuidString
                guard !itemID.isEmpty, !mcpLibraryItems(library).contains(where: { $0.id == itemID }) else { throw MCPDocumentCommandError.invalid("item_id is empty or already exists in this library.") }
                let item = LibraryItem(context: context)
                item.id = itemID; item.name = name; item.library = library
                item.elements = try MCPJSONValue.array(elements).mcpJSONData()
                item.status = "unpublished"; item.createdAt = Date(); item.rank = Int64(mcpLibraryItems(library).count)
                try await mcpPersistLibrary(library, context: context, suppliedFiles: mcpSuppliedLibraryFiles(arguments))
                return try mcpLibraryItemValue(item, includeElements: false)
            }
            let library = Library(name: name, context: context)
            library.type = "excalidrawlib"
            try await mcpPersistLibrary(library, context: context)
            return try await mcpLibraryValue(library)
        case "update":
            let library = try mcpLibrary(mcpRequiredString(arguments, "library_id"), context: context)
            let name = try arguments["name"]?.stringValue.map { try MCPDocumentCommandValidation.name($0) }
            let elements = try arguments["elements"].map { try MCPDocumentCommandValidation.elements($0) }
            let status = arguments["status"]?.stringValue
            if let status, status != "published" && status != "unpublished" { throw MCPDocumentCommandError.invalid("status must be published or unpublished.") }
            if let itemID = arguments["item_id"]?.stringValue {
                let item = try mcpLibraryItem(itemID, library: library)
                if let name { item.name = name }
                if let elements { item.elements = try MCPJSONValue.array(elements).mcpJSONData() }
                if let status { item.status = status }
                try await mcpPersistLibrary(library, context: context, suppliedFiles: mcpSuppliedLibraryFiles(arguments))
                return try mcpLibraryItemValue(item, includeElements: false)
            }
            guard let name, elements == nil, status == nil else { throw MCPDocumentCommandError.invalid("Updating a library requires name; elements/status require item_id.") }
            library.name = name
            try context.save()
            return try await mcpLibraryValue(library)
        case "delete":
            let library = try mcpLibrary(mcpRequiredString(arguments, "library_id"), context: context)
            if let itemID = arguments["item_id"]?.stringValue {
                context.delete(try mcpLibraryItem(itemID, library: library))
                try await mcpPersistLibrary(library, context: context)
            } else {
                let id = library.id
                context.delete(library)
                try context.save()
                if let id {
                    do { try MCPLibraryAssetStore.shared.remove(libraryID: id) }
                    catch { return .object(["deleted": .bool(true), "asset_cleanup_warning": .string(error.localizedDescription)]) }
                }
            }
            return .object(["deleted": .bool(true)])
        case "import":
            guard let raw = arguments["library"]?.objectValue, raw["type"]?.stringValue == "excalidrawlib",
                  let version = raw["version"]?.numberValue, version == 1 || version == 2 else { throw MCPDocumentCommandError.invalid("library must be a canonical excalidrawlib object of version 1 or 2.") }
            let itemValues: [MCPJSONValue]
            if version == 1 {
                guard let oldItems = raw["library"]?.arrayValue else { throw MCPDocumentCommandError.invalid("Version 1 libraries require a library array.") }
                itemValues = oldItems.enumerated().map { index, elements in .object(["id": .string(UUID().uuidString), "name": .string("Item \(index + 1)"), "elements": elements, "status": .string("published")]) }
            } else {
                guard let items = raw["libraryItems"]?.arrayValue else { throw MCPDocumentCommandError.invalid("Version 2 libraries require libraryItems.") }
                itemValues = items
            }
            guard itemValues.count <= 10_000 else { throw MCPDocumentCommandError.invalid("A library import is limited to 10,000 items.") }
            let importedFiles = try mcpSuppliedLibraryFiles(arguments, library: raw)
            // Validate every item before inserting any Core Data object.
            var seen = Set<String>()
            let records = try itemValues.map { value -> (String, String, String, Date, Data) in
                guard let item = value.objectValue else { throw MCPDocumentCommandError.invalid("Each library item must be an object.") }
                let id = try mcpRequiredString(item, "id")
                guard seen.insert(id).inserted else { throw MCPDocumentCommandError.invalid("Imported item IDs must be unique.") }
                let elements = try MCPDocumentCommandValidation.elements(item["elements"] ?? .null)
                let status = item["status"]?.stringValue ?? "published"
                guard status == "published" || status == "unpublished" else { throw MCPDocumentCommandError.invalid("Invalid library item status.") }
                let created = item["created"]?.numberValue ?? Date().timeIntervalSince1970 * 1_000
                guard created.isFinite, created >= 0 else { throw MCPDocumentCommandError.invalid("created must be a finite nonnegative timestamp in milliseconds.") }
                return (id, item["name"]?.stringValue ?? "Untitled", status, Date(timeIntervalSince1970: created / 1_000), try MCPJSONValue.array(elements).mcpJSONData())
            }
            let library: Library
            if let id = arguments["library_id"]?.stringValue { library = try mcpLibrary(id, context: context) }
            else { library = Library(name: try MCPDocumentCommandValidation.name(arguments["name"]?.stringValue ?? "Imported library"), context: context); library.type = "excalidrawlib" }
            let existing = Dictionary(mcpLibraryItems(library).compactMap { item in item.id.map { ($0, item) } }, uniquingKeysWith: { first, _ in first })
            guard arguments["replace_existing"] == .bool(true) || records.allSatisfy({ existing[$0.0] == nil }) else {
                if library.isInserted { context.delete(library) }
                throw MCPDocumentCommandError.invalid("Imported IDs already exist; set replace_existing:true to replace those items.")
            }
            library.version = 2
            if let source = raw["source"]?.stringValue { library.source = source }
            for (index, record) in records.enumerated() {
                let item = existing[record.0] ?? LibraryItem(context: context)
                item.id = record.0; item.name = record.1; item.status = record.2; item.createdAt = record.3; item.elements = record.4; item.library = library
                if item.isInserted { item.rank = Int64(existing.count + index) }
            }
            try await mcpPersistLibrary(library, context: context, suppliedFiles: importedFiles)
            return .object(["library_id": library.id.map { .string($0.uuidString) } ?? .null, "imported_count": .number(Double(records.count))])
        case "export":
            return try await mcpLibraryValue(mcpLibrary(mcpRequiredString(arguments, "library_id"), context: context), itemID: arguments["item_id"]?.stringValue)
        case "insert", "preview":
            let library = try mcpLibrary(mcpRequiredString(arguments, "library_id"), context: context)
            let item = try mcpLibraryItem(mcpRequiredString(arguments, "item_id"), library: library)
            guard let data = item.elements else { throw MCPDocumentCommandError.invalid("The library item has no elements.") }
            let raw = try MCPJSONValue.parse(from: data)
            let elements = try MCPDocumentCommandValidation.elements(raw)
            let files = try await mcpLibraryAssets(elements, context: context, libraryID: library.id)
            if action == "insert" {
                let insertion = try MCPDocumentCommandValidation.insertion(raw, x: arguments["x"]?.numberValue ?? 0, y: arguments["y"]?.numberValue ?? 0)
                let portable = try MCPDocumentCommandValidation.remappingAssets(in: insertion, files: files)
                // The diagram service commits this preparation through the
                // revisioned atomic engine, with its undo/checkpoint contract.
                return .object(["prepared_elements": .array(portable.elements), "files": .object(portable.files), "library_id": .string(try mcpRequiredString(arguments, "library_id")), "item_id": .string(try mcpRequiredString(arguments, "item_id"))])
            }
            let id = try mcpRequiredString(arguments, "document_id")
            let (_, coordinator) = try await requireMCPDocument(documentID: id, requiresMutation: false)
            let typed = try JSONDecoder().decode([ExcalidrawElement].self, from: data)
            let resources = try JSONDecoder().decode([String: ExcalidrawFile.ResourceFile].self, from: MCPJSONValue.object(files).mcpJSONData())
            let png = try await coordinator.exportElementsToPNGData(elements: typed, files: resources, withBackground: arguments["with_background"] != .bool(false), colorScheme: .light)
            let bounded = try mcpBoundedPreview(png)
            return .object(["image": .object(["mime_type": .string("image/png"), "data": .string(bounded.base64EncodedString())]), "item_id": .string(try mcpRequiredString(arguments, "item_id"))])
        default: throw MCPDocumentCommandError.invalid("Unsupported library action: \(action).")
        }
    }

    private func mcpLibrary(_ id: String, context: NSManagedObjectContext) throws -> Library {
        guard let uuid = UUID(uuidString: id) else { throw MCPDocumentCommandError.invalid("library_id must be a UUID.") }
        let request = NSFetchRequest<Library>(entityName: "Library")
        request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg); request.fetchLimit = 1
        guard let library = try context.fetch(request).first else { throw MCPDocumentCommandError.unavailable("Library not found: \(id).") }
        return library
    }

    private func mcpBoundedPreview(_ png: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1_600,
                kCGImageSourceShouldCache: false
              ] as CFDictionary) else { throw MCPDocumentCommandError.unavailable("The library image preview could not be decoded.") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw MCPDocumentCommandError.unavailable("The library image preview could not be encoded.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MCPDocumentCommandError.unavailable("The library image preview could not be finalized.") }
        return data as Data
    }

    private func mcpLibraryItems(_ library: Library) -> [LibraryItem] {
        (library.items?.allObjects as? [LibraryItem] ?? []).filter { !$0.isDeleted }.sorted { $0.rank == $1.rank ? ($0.id ?? "") < ($1.id ?? "") : $0.rank < $1.rank }
    }

    private func mcpLibraryItem(_ id: String, library: Library) throws -> LibraryItem {
        guard let item = mcpLibraryItems(library).first(where: { $0.id == id }) else { throw MCPDocumentCommandError.unavailable("Library item not found: \(id).") }
        return item
    }

    private func mcpLibraryItemValue(_ item: LibraryItem, includeElements: Bool) throws -> MCPJSONValue {
        var value: [String: MCPJSONValue] = ["library_id": item.library?.id.map { .string($0.uuidString) } ?? .null, "item_id": .string(item.id ?? ""), "id": .string(item.id ?? ""), "name": .string(item.name ?? "Untitled"), "status": .string(item.status ?? "published"), "created": .number((item.createdAt ?? .distantPast).timeIntervalSince1970 * 1_000), "rank": .number(Double(item.rank))]
        if let data = item.elements {
            let raw = try MCPJSONValue.parse(from: data)
            value["element_count"] = .number(Double(raw.arrayValue?.count ?? 0))
            if includeElements { value["elements"] = raw }
        }
        return .object(value)
    }

    private func mcpLibraryValue(_ library: Library, itemID: String? = nil) async throws -> MCPJSONValue {
        let items = try itemID.map { [try mcpLibraryItem($0, library: library)] } ?? mcpLibraryItems(library)
        let values = try items.map { item -> MCPJSONValue in
            var value = try mcpLibraryItemValue(item, includeElements: true).objectValue!
            value.removeValue(forKey: "library_id"); value.removeValue(forKey: "item_id"); value.removeValue(forKey: "rank"); value.removeValue(forKey: "element_count")
            return .object(value)
        }
        guard let context = library.managedObjectContext else { throw BridgeError.appContextUnavailable }
        let elements = values.flatMap { $0["elements"]?.arrayValue ?? [] }
        let files = try await mcpLibraryAssets(elements, context: context, libraryID: library.id)
        return .object(["library_id": library.id.map { .string($0.uuidString) } ?? .null, "name": .string(library.name ?? "Untitled"), "type": .string("excalidrawlib"), "version": .number(2), "source": .string(library.source ?? "https://excalidraw.com"), "libraryItems": .array(values), "files": .object(files)])
    }

    private func mcpLibraryAssets(_ elements: [MCPJSONValue], context: NSManagedObjectContext, libraryID: UUID? = nil, suppliedFiles: [String: MCPJSONValue] = [:]) async throws -> [String: MCPJSONValue] {
        let ids = Set(elements.filter { $0["type"]?.stringValue == "image" }.compactMap { $0["fileId"]?.stringValue })
        var saved = try libraryID.map { try MCPLibraryAssetStore.shared.load(libraryID: $0) } ?? [:]
        saved.merge(suppliedFiles) { _, new in new }
        var assets: [String: MCPJSONValue] = [:]
        for id in ids {
            if let resource = saved[id] { assets[id] = resource; continue }
            let request = NSFetchRequest<MediaItem>(entityName: "MediaItem")
            request.predicate = NSPredicate(format: "id == %@", id); request.fetchLimit = 1
            guard let media = try context.fetch(request).first else { throw MCPDocumentCommandError.unavailable("Missing image asset \(id). Import the image into a drawing before inserting this library item.") }
            if let file = media.file {
                guard AIChatPreferences.shared.allowsFileAccess(for: .file(file)), try await LockedContentAIGuard.canToolAccess(fileObjectID: file.objectID) else { throw BridgeError.currentFileAccessDenied }
            }
            guard media.collaborationFile == nil else { throw BridgeError.unsupportedActiveFile("Library assets from collaboration documents are outside Full MCP's local document scope.") }
            let resource = try await ExcalidrawFile.ResourceFile(mediaItem: media)
            assets[id] = try MCPJSONValue.parse(from: JSONEncoder().encode(resource))
        }
        return assets
    }

    private func mcpSuppliedLibraryFiles(_ arguments: [String: MCPJSONValue], library: [String: MCPJSONValue]? = nil) throws -> [String: MCPJSONValue] {
        if let value = arguments["files"], value.objectValue == nil { throw MCPDocumentCommandError.invalid("files must be an object of canonical image resources keyed by file ID.") }
        if let value = library?["files"], value.objectValue == nil { throw MCPDocumentCommandError.invalid("library.files must be an object of image resources.") }
        var files = library?["files"]?.objectValue ?? [:]
        for (id, resource) in arguments["files"]?.objectValue ?? [:] {
            guard files[id] == nil || files[id] == resource else { throw MCPDocumentCommandError.invalid("Conflicting image resource \(id) in files and library.files.") }
            files[id] = resource
        }
        try MCPLibraryAssetStore.validate(files)
        return files
    }

    private func mcpPersistLibrary(_ library: Library, context: NSManagedObjectContext, suppliedFiles: [String: MCPJSONValue] = [:]) async throws {
        guard let id = library.id else { throw MCPDocumentCommandError.invalid("The library has no stable ID.") }
        let elements = try mcpLibraryItems(library).flatMap { item -> [MCPJSONValue] in
            guard let data = item.elements else { return [] }
            return try MCPJSONValue.parse(from: data).arrayValue ?? []
        }
        for element in elements where element["type"]?.stringValue == "image" {
            guard element["fileId"]?.stringValue != nil else { throw MCPDocumentCommandError.invalid("Library images require a fileId and matching image bytes.") }
        }
        let assets = try await mcpLibraryAssets(elements, context: context, libraryID: id, suppliedFiles: suppliedFiles)
        let backup = try MCPLibraryAssetStore.shared.save(assets, libraryID: id)
        do { try context.save() }
        catch {
            try? MCPLibraryAssetStore.shared.restore(backup, libraryID: id)
            throw error
        }
    }

    func fullPresentationCommand(arguments: [String: MCPJSONValue]) async throws -> MCPJSONValue {
        var arguments = arguments
        if arguments["frame_order"] == nil { arguments["frame_order"] = arguments["frame_ids"] }
        if arguments["frame_id"] == nil { arguments["frame_id"] = arguments["initial_frame_id"] }
        let action = try mcpRequiredString(arguments, "action")
        let id = try mcpRequiredString(arguments, "document_id")
        let (state, coordinator) = try await requireMCPDocument(documentID: id, requiresMutation: action == "configure")
        guard let active = state.currentActiveFile, let context = mcpContext else { throw BridgeError.appContextUnavailable }
        if action == "configure" { _ = try await mcpEnsureRevision(arguments: arguments, documentID: id, coordinator: coordinator) }
        if action == "stop" {
            guard MCPDocumentCommandState.shared.presentationDocumentID == id else { throw MCPDocumentCommandError.invalid("This document has no active MCP presentation.") }
            ExcalidrawPresentationController.shared.dismiss()
            MCPDocumentCommandState.shared.presentationDocumentID = nil
            return .object(["document_id": .string(id), "presenting": .bool(false)])
        }
        let snapshot = try await coordinator.getCurrentFileSnapshot(includeFiles: false)
        let scene = try MCPJSONValue.parse(from: snapshot.documentData(includeFiles: false))
        let frames = (scene["elements"]?.arrayValue ?? []).filter { $0["type"]?.stringValue == "frame" && $0["isDeleted"] != .bool(true) }
        let frameIDs = frames.compactMap { $0["id"]?.stringValue }
        var configuration = try await mcpLoadPresentation(active, context: context).reconciled(withFrameIDs: frameIDs)
        if action == "configure" {
            if let order = arguments["frame_order"]?.arrayValue {
                let ids = order.compactMap(\.stringValue)
                guard ids.count == order.count, ids.count == frameIDs.count, Set(ids) == Set(frameIDs) else { throw MCPDocumentCommandError.invalid("frame_order must include every current frame ID exactly once.") }
                let pages = Dictionary(configuration.pages.map { ($0.frameID, $0) }, uniquingKeysWith: { first, _ in first })
                configuration.pages = ids.compactMap { pages[$0] }
            }
            if let values = arguments["pages"]?.arrayValue {
                var seen = Set<String>()
                for value in values {
                    guard let page = value.objectValue else { throw MCPDocumentCommandError.invalid("pages must contain page objects.") }
                    let frameID = try mcpRequiredString(page, "frame_id")
                    guard seen.insert(frameID).inserted, let index = configuration.pages.firstIndex(where: { $0.frameID == frameID }) else { throw MCPDocumentCommandError.invalid("Unknown or repeated presentation frame: \(frameID).") }
                    if let hidden = page["hidden"] {
                        guard case .bool(let value) = hidden else { throw MCPDocumentCommandError.invalid("hidden must be a boolean.") }
                        configuration.pages[index].isHidden = value
                    }
                    if let transition = page["transition"]?.stringValue {
                        guard let transition = ExcalidrawPresentationConfiguration.Transition(rawValue: transition) else { throw MCPDocumentCommandError.invalid("transition must be none, fade, slide, or zoom.") }
                        configuration.pages[index].transition = transition
                    }
                    if let duration = page["transition_duration"]?.numberValue {
                        guard duration.isFinite, duration >= 0.1, duration <= 3 else { throw MCPDocumentCommandError.invalid("transition_duration must be between 0.1 and 3 seconds.") }
                        configuration.pages[index].transitionDuration = duration
                    }
                    if let notes = page["speaker_notes"]?.stringValue { configuration.pages[index].speakerNotes = notes }
                }
            }
            _ = try await mcpEnsureRevision(arguments: arguments, documentID: id, coordinator: coordinator)
            try await mcpSavePresentation(configuration, active: active, context: context)
        } else if action == "start" || action == "go_to" {
            if action == "go_to", MCPDocumentCommandState.shared.presentationDocumentID != id { throw MCPDocumentCommandError.invalid("Start this document's presentation before using go_to.") }
            let model = ExcalidrawPresentationModel()
            guard await model.load(activeFile: active, coordinator: coordinator, colorScheme: .light, contentChangeToken: nil) else { throw MCPDocumentCommandError.unavailable("The presentation slides could not be rendered.") }
            let slidesByID = Dictionary(model.slides.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let slides = configuration.pages.filter { !$0.isHidden }.compactMap { page -> ExcalidrawPresentationSlide? in
                guard var slide = slidesByID[page.frameID] else { return nil }
                slide.transition = page.transition; slide.transitionDuration = page.transitionDuration; slide.speakerNotes = page.speakerNotes
                return slide
            }
            guard !slides.isEmpty else { throw MCPDocumentCommandError.invalid("Create at least one visible frame before presenting.") }
            let initial = arguments["frame_id"]?.stringValue ?? slides.first!.id
            guard slides.contains(where: { $0.id == initial }) else { throw MCPDocumentCommandError.invalid("frame_id must identify a visible presentation frame.") }
            ExcalidrawPresentationController.shared.present(title: arguments["title"]?.stringValue ?? active.name ?? "Diagram", slides: slides, initialSlideID: initial)
            MCPDocumentCommandState.shared.presentationDocumentID = id
        } else if action != "list" { throw MCPDocumentCommandError.invalid("Unsupported presentation action: \(action).") }
        let framesByID = Dictionary(frames.compactMap { frame in frame["id"]?.stringValue.map { ($0, frame) } }, uniquingKeysWith: { first, _ in first })
        return .object(["document_id": .string(id), "presenting": .bool(MCPDocumentCommandState.shared.presentationDocumentID == id && ExcalidrawPresentationController.shared.session != nil), "pages": .array(configuration.pages.map { page in .object(["frame_id": .string(page.frameID), "name": framesByID[page.frameID]?["name"] ?? .null, "hidden": .bool(page.isHidden), "transition": .string(page.transition.rawValue), "transition_duration": .number(page.transitionDuration), "speaker_notes": .string(page.speakerNotes)]) }), "persistence": .string(action == "configure" ? "saved" : "unchanged")])
    }

    private func mcpLoadPresentation(_ active: FileState.ActiveFile, context: NSManagedObjectContext) async throws -> ExcalidrawPresentationConfiguration {
        switch active {
        case .file(let file): return try await PersistenceController.shared.presentationConfigurationRepository.load(for: .libraryFile(objectURI: file.objectID.uriRepresentation()))
        case .localFile(let url):
            let (_, folder) = try mcpApprovedLocalDocument(url.absoluteString, context: context)
            return try mcpWithScopedURL(folder) { root in
                let sidecar = mcpPresentationSidecar(url)
                guard MCPDocumentCommandValidation.contained(sidecar, in: root) else { throw BridgeError.currentFileAccessDenied }
                guard FileManager.default.fileExists(atPath: sidecar.path) else { return ExcalidrawPresentationConfiguration() }
                return try JSONDecoder().decode(ExcalidrawPresentationConfiguration.self, from: Data(contentsOf: sidecar))
            }
        default: throw BridgeError.unsupportedActiveFile("Presentation supports managed and approved local documents.")
        }
    }

    private func mcpSavePresentation(_ configuration: ExcalidrawPresentationConfiguration, active: FileState.ActiveFile, context: NSManagedObjectContext) async throws {
        switch active {
        case .file(let file):
            let commandContext = mcpIsolatedMetadataContext(context)
            guard let target = try commandContext.existingObject(with: file.objectID) as? File else { throw BridgeError.fileNotFound(active.id) }
            target.presentationData = try JSONEncoder().encode(configuration)
            try commandContext.save()
        case .localFile(let url):
            let (_, folder) = try mcpApprovedLocalDocument(url.absoluteString, context: context)
            try await folder.withSecurityScopedURL { root in
                let sidecar = self.mcpPresentationSidecar(url)
                guard MCPDocumentCommandValidation.contained(sidecar, in: root) else { throw BridgeError.currentFileAccessDenied }
                try await FileCoordinator.shared.coordinatedWrite(url: sidecar, data: JSONEncoder().encode(configuration))
            }
        default: throw BridgeError.unsupportedActiveFile("Presentation supports managed and approved local documents.")
        }
    }

    func fullCheckpointCommand(arguments: [String: MCPJSONValue]) async throws -> MCPJSONValue {
        let action = try mcpRequiredString(arguments, "action")
        let id = try mcpRequiredString(arguments, "document_id")
        let (state, coordinator) = try await requireMCPDocument(documentID: id, requiresMutation: action == "create")
        guard let active = state.currentActiveFile, let appContext = mcpContext else { throw BridgeError.appContextUnavailable }
        if action == "create" {
            _ = try await mcpEnsureRevision(arguments: arguments, documentID: id, coordinator: coordinator)
            let checkpointID = try await fullMCPCheckpoint(documentID: id, description: arguments["description"]?.stringValue ?? "MCP checkpoint", before: false)
            let inspection = try await coordinator.performDiagramCommand(["action": .string("inspect"), "document_id": .string(id), "limit": .number(1)])
            return .object(["document_id": .string(id), "checkpoint_id": .string(checkpointID), "revision": inspection["revision"] ?? .null, "persistence": .string("saved")])
        }
        if action == "diff" {
            let before = try await fullCheckpointScene(arguments: arguments)
            let current: MCPJSONValue
            if let compareID = arguments["compare_checkpoint_id"]?.stringValue {
                var comparison = arguments; comparison["checkpoint_id"] = .string(compareID)
                current = try await fullCheckpointScene(arguments: comparison)
            } else {
                let snapshot = try await coordinator.getCurrentFileSnapshot(includeFiles: true)
                current = try MCPJSONValue.parse(from: snapshot.documentData(includeFiles: true))
            }
            var result = MCPDocumentCommandValidation.sceneDiff(before: before, after: current).objectValue ?? [:]
            result["document_id"] = .string(id); result["checkpoint_id"] = arguments["checkpoint_id"]
            result["revision"] = try await coordinator.performDiagramCommand(["action": .string("inspect"), "document_id": .string(id), "limit": .number(1)])["revision"] ?? .null
            return .object(result)
        }
        if action == "read" {
            return .object(["document_id": .string(id), "checkpoint_id": arguments["checkpoint_id"] ?? .null, "scene": try await fullCheckpointScene(arguments: arguments)])
        }
        guard action == "list" else { throw MCPDocumentCommandError.invalid("Unsupported checkpoint action: \(action). Restore is committed by the diagram command service.") }
        let context = mcpIsolatedMetadataContext(appContext)
        let limit = try mcpPageInteger(arguments, "limit", default: 50, maximum: 200)
        let offset = try mcpPageInteger(arguments, "offset", default: 0, maximum: 1_000_000)
        let count: Int, entries: [MCPJSONValue]
        switch active {
        case .file(let file):
            let request = NSFetchRequest<FileCheckpoint>(entityName: "FileCheckpoint")
            let target = try context.existingObject(with: file.objectID)
            request.predicate = NSPredicate(format: "file == %@", target)
            request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false), NSSortDescriptor(key: "id", ascending: true)]
            count = try context.count(for: request); request.fetchOffset = offset; request.fetchLimit = limit
            entries = try context.fetch(request).map { checkpoint in .object(["checkpoint_id": checkpoint.id.map { .string($0.uuidString) } ?? .null, "source": .string(checkpoint.source ?? "user"), "description": checkpoint.historyDescription.map(MCPJSONValue.string) ?? .null, "created_at": checkpoint.updatedAt.map { .string(Self.iso8601String(from: $0)) } ?? .null]) }
        case .localFile(let url):
            _ = try mcpApprovedLocalDocument(url.absoluteString, context: context)
            let request = NSFetchRequest<LocalFileCheckpoint>(entityName: "LocalFileCheckpoint")
            request.predicate = NSPredicate(format: "url == %@", url.standardizedFileURL as NSURL)
            request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false), NSSortDescriptor(key: "id", ascending: true)]
            count = try context.count(for: request); request.fetchOffset = offset; request.fetchLimit = limit
            entries = try context.fetch(request).map { checkpoint in .object(["checkpoint_id": checkpoint.id.map { .string($0.uuidString) } ?? .null, "source": .string(checkpoint.source ?? "user"), "description": checkpoint.historyDescription.map(MCPJSONValue.string) ?? .null, "created_at": checkpoint.updatedAt.map { .string(Self.iso8601String(from: $0)) } ?? .null]) }
        default: throw BridgeError.unsupportedActiveFile("Checkpoint listing supports managed and approved local documents.")
        }
        return .object(["document_id": .string(id), "checkpoints": .array(entries), "returned": .number(Double(entries.count)), "total": .number(Double(count)), "next_offset": offset + entries.count < count ? .number(Double(offset + entries.count)) : .null])
    }

    /// Resolves a checkpoint only within the explicitly addressed document.
    /// Returning its raw envelope lets the command service perform one CAS
    /// replace_scene operation with native undo and a recovery checkpoint.
    func fullCheckpointScene(arguments: [String: MCPJSONValue]) async throws -> MCPJSONValue {
        let id = try mcpRequiredString(arguments, "document_id")
        let rawCheckpointID = try mcpRequiredString(arguments, "checkpoint_id")
        guard let checkpointID = UUID(uuidString: rawCheckpointID) else { throw MCPDocumentCommandError.invalid("checkpoint_id must be a UUID.") }
        let (state, _) = try await requireMCPDocument(documentID: id, requiresMutation: arguments["action"] == .string("restore"))
        guard let active = state.currentActiveFile, let appContext = mcpContext else { throw BridgeError.appContextUnavailable }
        let context = mcpIsolatedMetadataContext(appContext)
        let content: Data
        switch active {
        case .file(let file):
            let request = NSFetchRequest<FileCheckpoint>(entityName: "FileCheckpoint")
            let target = try context.existingObject(with: file.objectID)
            request.predicate = NSPredicate(format: "id == %@ AND file == %@", checkpointID as CVarArg, target)
            request.fetchLimit = 1
            guard let checkpoint = try context.fetch(request).first else { throw MCPDocumentCommandError.unavailable("Checkpoint not found in the addressed document: \(rawCheckpointID).") }
            content = try await checkpoint.loadContent()
        case .localFile(let url):
            _ = try mcpApprovedLocalDocument(url.absoluteString, context: context)
            let request = NSFetchRequest<LocalFileCheckpoint>(entityName: "LocalFileCheckpoint")
            request.predicate = NSPredicate(format: "id == %@ AND url == %@", checkpointID as CVarArg, url.standardizedFileURL as NSURL)
            request.fetchLimit = 1
            guard let checkpoint = try context.fetch(request).first, let stored = checkpoint.content else { throw MCPDocumentCommandError.unavailable("Checkpoint content not found in the addressed document: \(rawCheckpointID).") }
            content = stored
        default: throw BridgeError.unsupportedActiveFile("Checkpoint recovery supports managed and approved local documents.")
        }
        guard var scene = try MCPJSONValue.parse(from: content).objectValue, let elements = scene["elements"]?.arrayValue else { throw BridgeError.invalidGeneratedFile("The checkpoint is not an Excalidraw scene.") }
        var files = scene["files"]?.objectValue ?? [:]
        let unresolvedImages = elements.filter { $0["type"]?.stringValue == "image" && $0["fileId"]?.stringValue.map { files[$0] == nil } == true }
        for (id, asset) in try await mcpLibraryAssets(unresolvedImages, context: context) { files[id] = asset }
        scene["files"] = .object(files)
        scene["type"] = scene["type"] ?? .string("excalidraw")
        scene["version"] = scene["version"] ?? .number(2)
        scene["source"] = scene["source"] ?? .string("https://excalidraw.com")
        return .object(scene)
    }
}
