//
//  ExcalidrawMCPOptimizedTools.swift
//  ExcalidrawZ
//
//  Created by Codex on 2026/06/16.
//

import Foundation
import LLMCore

enum ExcalidrawMCPOptimizedContract {
    static let instructions = ExcalidrawMCPOptimizedResources.text(
        named: "ExcalidrawMCPOptimizedInstructions",
        fallback: """
        You are connected to the local ExcalidrawZ MCP server. Call read_me before editing.
        Read the current file or view before changing it, use targeted operations, and respect
        the app's file-access and locked-content boundaries. Use dry runs when a mutation tool
        supports them. Local MCP access does not enable cloud AI services.
        """
    )

    enum ToolName {
        static let readMe = ExcalidrawMCPUpstreamContract.ToolName.readMe
        static let readView = "read_view"
        static let replaceView = "replace_view"
        static let getAppContext = "get_app_context"
        static let getCurrentFile = "get_current_file"
        static let listGroups = "list_groups"
        static let listFiles = "list_files"
        static let listLocalFolders = "list_local_folders"
        static let listLocalFiles = "list_local_files"
        static let getCurrentFileCheckpoints = "get_current_file_checkpoints"
        static let createFile = "create_file"
        static let createLocalFile = "create_local_file"
        static let openFile = "open_file"
        static let openLocalFile = "open_local_file"
        static let setCanvasPreferences = "set_canvas_preferences"
    }
}

enum ExcalidrawMCPOptimizedRecall {
    static let guide = ExcalidrawMCPOptimizedResources.text(
        named: "ExcalidrawMCPOptimizedReadMe",
        fallback: """
        # ExcalidrawZ local MCP

        Use `get_app_context` and `get_current_file` to establish the active target. Use
        `read_view` for the current scene and `read_file` for filtered element queries.
        Prefer `adjust_elements` for focused changes and `replace_view` only when replacing
        the complete element array. `insert_math` adds formulas and function plots. File tools
        operate only on app-managed files or folders the user explicitly allowed in ExcalidrawZ.
        Locked content remains unavailable. Mutation tools record app history checkpoints when
        the current target supports them.
        """
    )
}

extension ExcalidrawMCPToolSchemas {
    static let optimizedReadView = ExcalidrawMCPOptimizedResources.schema(named: "read_view")
    static let optimizedReplaceView = ExcalidrawMCPOptimizedResources.schema(named: "replace_view")
    static let optimizedCreateFile = ExcalidrawMCPOptimizedResources.schema(named: "create_file")
    static let optimizedListGroups = ExcalidrawMCPOptimizedResources.schema(named: "list_groups")
    static let optimizedListLocalFolders = ExcalidrawMCPOptimizedResources.schema(named: "list_local_folders")
    static let optimizedListLocalFiles = ExcalidrawMCPOptimizedResources.schema(named: "list_local_files")
    static let optimizedCreateLocalFile = ExcalidrawMCPOptimizedResources.schema(named: "create_local_file")
    static let optimizedOpenLocalFile = ExcalidrawMCPOptimizedResources.schema(named: "open_local_file")
    static let optimizedOpenFile = ExcalidrawMCPOptimizedResources.schema(named: "open_file")
    static let optimizedSetCanvasPreferences = ExcalidrawMCPOptimizedResources.schema(named: "set_canvas_preferences")
    static let optimizedExport = ExcalidrawMCPOptimizedResources.schema(named: "export")
    static let optimizedGetCurrentFileCheckpoints = ExcalidrawMCPOptimizedResources.schema(named: "get_current_file_checkpoints")
    static let optimizedRenameFile = ExcalidrawMCPOptimizedResources.schema(named: "rename_file")
}

enum ExcalidrawMCPOptimizedToolCatalog {
    static var tools: [ExcalidrawMCPTool] {
        baseTools + appToolAdapters.map(\.mcpTool) + [replaceViewTool]
    }

    static let appToolAdapters: [ExcalidrawMCPLLMCoreToolAdapter] = [
        ExcalidrawMCPLLMCoreToolAdapter(
            tool: FileAccessStatusTool(),
            title: "File Access Status",
            annotations: ["readOnlyHint": .bool(true)],
            contextProvider: {
                await ExcalidrawMCPAppBridge.shared.optimizedFileAccessStatusContext()
            }
        ),
        ExcalidrawMCPLLMCoreToolAdapter(
            tool: ReadFileTool(),
            title: "Read File",
            annotations: ["readOnlyHint": .bool(true)],
            contextProvider: {
                try await ExcalidrawMCPAppBridge.shared.optimizedChatToolContext(
                    requiresMutation: false
                )
            }
        ),
        ExcalidrawMCPLLMCoreToolAdapter(
            tool: ReadCanvasImageTool(),
            title: "Read Canvas Image",
            description: description("read_canvas_image"),
            annotations: ["readOnlyHint": .bool(true)],
            contextProvider: {
                try await ExcalidrawMCPAppBridge.shared.optimizedChatToolContext(
                    requiresMutation: false
                )
            }
        ),
        ExcalidrawMCPLLMCoreToolAdapter(
            tool: ExportTool(),
            title: "Export",
            description: description("export"),
            schemaOverride: ExcalidrawMCPToolSchemas.optimizedExport,
            annotations: ["readOnlyHint": .bool(true)],
            contextProvider: {
                try await ExcalidrawMCPAppBridge.shared.optimizedChatToolContext(
                    requiresMutation: false,
                    requiresActiveFile: true
                )
            }
        ),
        ExcalidrawMCPLLMCoreToolAdapter(
            tool: NavigateCanvasTool(),
            title: "Navigate Canvas",
            contextProvider: {
                try await ExcalidrawMCPAppBridge.shared.optimizedChatToolContext(
                    requiresMutation: false
                )
            }
        ),
        ExcalidrawMCPLLMCoreToolAdapter(
            tool: InsertMathTool(),
            title: "Math",
            description: description("insert_math"),
            contextProvider: {
                try await ExcalidrawMCPAppBridge.shared.optimizedChatToolContext(
                    requiresMutation: true,
                    requiresActiveFile: true
                )
            },
            mutationCheckpointDescription: "MCP insert_math"
        ),
        ExcalidrawMCPLLMCoreToolAdapter(
            tool: AdjustElementsTool(),
            title: "Adjust Elements",
            description: description("adjust_elements"),
            contextProvider: {
                try await ExcalidrawMCPAppBridge.shared.optimizedChatToolContext(
                    requiresMutation: true,
                    requiresActiveFile: true
                )
            },
            mutationCheckpointDescription: "MCP adjust_elements"
        ),
        ExcalidrawMCPLLMCoreToolAdapter(
            tool: RenameFileTool(),
            title: "Rename File",
            description: description("rename_file"),
            schemaOverride: ExcalidrawMCPToolSchemas.optimizedRenameFile,
            contextProvider: {
                try await ExcalidrawMCPAppBridge.shared.optimizedChatToolContext(
                    requiresMutation: true
                )
            }
        ),
        ExcalidrawMCPLLMCoreToolAdapter(
            tool: ListAllFilesTool(),
            exposedName: ExcalidrawMCPOptimizedContract.ToolName.listFiles,
            title: "List Files",
            description: description("list_files"),
            annotations: ["readOnlyHint": .bool(true)]
        ),
        ExcalidrawMCPLLMCoreToolAdapter(
            tool: QueryFileHistoryTool(),
            exposedName: ExcalidrawMCPOptimizedContract.ToolName.getCurrentFileCheckpoints,
            title: "Get Current File Checkpoints",
            description: description("get_current_file_checkpoints"),
            schemaOverride: ExcalidrawMCPToolSchemas.optimizedGetCurrentFileCheckpoints,
            annotations: ["readOnlyHint": .bool(true)],
            normalizeArguments: { arguments in
                var normalized = arguments
                normalized.removeValue(forKey: "file_id")
                normalized.removeValue(forKey: "file_url")
                for (key, value) in try await ExcalidrawMCPAppBridge.shared.optimizedActiveCheckpointTargetArguments() {
                    normalized[key] = value
                }
                return normalized
            }
        ),
        ExcalidrawMCPLLMCoreToolAdapter(
            tool: ListLibrariesTool(),
            title: "List Libraries",
            annotations: ["readOnlyHint": .bool(true)]
        ),
        ExcalidrawMCPLLMCoreToolAdapter(
            tool: ListLibraryItemsTool(),
            title: "List Library Items",
            description: description("list_library_items"),
            annotations: ["readOnlyHint": .bool(true)]
        ),
        ExcalidrawMCPLLMCoreToolAdapter(
            tool: QueryLibraryItemTool(),
            title: "Query Library Item",
            annotations: ["readOnlyHint": .bool(true)]
        ),
        ExcalidrawMCPLLMCoreToolAdapter(
            tool: AddLibraryItemToCanvasTool(),
            title: "Add Library Item to Canvas",
            contextProvider: {
                try await ExcalidrawMCPAppBridge.shared.optimizedChatToolContext(
                    requiresMutation: true
                )
            }
        ),
        ExcalidrawMCPLLMCoreToolAdapter(
            tool: RestoreFileHistoryTool(),
            title: "Restore File History",
            description: description("restore_file_history"),
            contextProvider: {
                try await ExcalidrawMCPAppBridge.shared.optimizedChatToolContext(
                    requiresMutation: true
                )
            }
        )
    ]

    private static let baseTools: [ExcalidrawMCPTool] = [
        ExcalidrawMCPTool(
            name: ExcalidrawMCPOptimizedContract.ToolName.readMe,
            title: "Read ExcalidrawZ MCP Guide",
            description: description("read_me"),
            inputSchema: ExcalidrawMCPToolSchemas.emptyObject,
            annotations: ["readOnlyHint": .bool(true)]
        ),
        ExcalidrawMCPTool(
            name: ExcalidrawMCPOptimizedContract.ToolName.getAppContext,
            title: "Get App Context",
            description: description("get_app_context"),
            inputSchema: ExcalidrawMCPToolSchemas.emptyObject,
            annotations: ["readOnlyHint": .bool(true)]
        ),
        ExcalidrawMCPTool(
            name: ExcalidrawMCPOptimizedContract.ToolName.getCurrentFile,
            title: "Get Current File",
            description: description("get_current_file"),
            inputSchema: ExcalidrawMCPToolSchemas.emptyObject,
            annotations: ["readOnlyHint": .bool(true)]
        ),
        ExcalidrawMCPTool(
            name: ExcalidrawMCPOptimizedContract.ToolName.listGroups,
            title: "List Groups",
            description: description("list_groups"),
            inputSchema: ExcalidrawMCPToolSchemas.optimizedListGroups,
            annotations: ["readOnlyHint": .bool(true)]
        ),
        ExcalidrawMCPTool(
            name: ExcalidrawMCPOptimizedContract.ToolName.listLocalFolders,
            title: "List Local Folders",
            description: description("list_local_folders"),
            inputSchema: ExcalidrawMCPToolSchemas.optimizedListLocalFolders,
            annotations: ["readOnlyHint": .bool(true)]
        ),
        ExcalidrawMCPTool(
            name: ExcalidrawMCPOptimizedContract.ToolName.listLocalFiles,
            title: "List Local Files",
            description: description("list_local_files"),
            inputSchema: ExcalidrawMCPToolSchemas.optimizedListLocalFiles,
            annotations: ["readOnlyHint": .bool(true)]
        ),
        ExcalidrawMCPTool(
            name: ExcalidrawMCPOptimizedContract.ToolName.createFile,
            title: "Create File",
            description: description("create_file"),
            inputSchema: ExcalidrawMCPToolSchemas.optimizedCreateFile
        ),
        ExcalidrawMCPTool(
            name: ExcalidrawMCPOptimizedContract.ToolName.createLocalFile,
            title: "Create Local File",
            description: description("create_local_file"),
            inputSchema: ExcalidrawMCPToolSchemas.optimizedCreateLocalFile
        ),
        ExcalidrawMCPTool(
            name: ExcalidrawMCPOptimizedContract.ToolName.openFile,
            title: "Open File",
            description: description("open_file"),
            inputSchema: ExcalidrawMCPToolSchemas.optimizedOpenFile
        ),
        ExcalidrawMCPTool(
            name: ExcalidrawMCPOptimizedContract.ToolName.openLocalFile,
            title: "Open Local File",
            description: description("open_local_file"),
            inputSchema: ExcalidrawMCPToolSchemas.optimizedOpenLocalFile
        ),
        ExcalidrawMCPTool(
            name: ExcalidrawMCPOptimizedContract.ToolName.readView,
            title: "Read View",
            description: description("read_view"),
            inputSchema: ExcalidrawMCPToolSchemas.optimizedReadView,
            annotations: ["readOnlyHint": .bool(true)]
        ),
        ExcalidrawMCPTool(
            name: ExcalidrawMCPOptimizedContract.ToolName.setCanvasPreferences,
            title: "Set Canvas Preferences",
            description: description("set_canvas_preferences"),
            inputSchema: ExcalidrawMCPToolSchemas.optimizedSetCanvasPreferences
        )
    ]

    private static let replaceViewTool = ExcalidrawMCPTool(
        name: ExcalidrawMCPOptimizedContract.ToolName.replaceView,
        title: "Replace View",
        description: description("replace_view"),
        inputSchema: ExcalidrawMCPToolSchemas.optimizedReplaceView
    )

    private static func description(_ key: String) -> String {
        ExcalidrawMCPOptimizedResources.description(named: key)
    }
}

struct ExcalidrawMCPOptimizedToolHandler {
    struct PublishedDiagram: Sendable {
        let appPreCheckpointID: String?
        let appPostCheckpointID: String?
        let appCheckpointWarning: String?

        init(
            appPreCheckpointID: String? = nil,
            appPostCheckpointID: String? = nil,
            appCheckpointWarning: String? = nil
        ) {
            self.appPreCheckpointID = appPreCheckpointID
            self.appPostCheckpointID = appPostCheckpointID
            self.appCheckpointWarning = appCheckpointWarning
        }
    }

    struct CurrentCanvasOptions: Sendable {
        var includeElements: Bool = true
        var includeAppState: Bool = true
        var includeFiles: Bool = false
    }

    typealias ElementConverter = @Sendable ([MCPJSONValue]) async throws -> [MCPJSONValue]
    typealias PublishDiagram = @Sendable (
        _ elements: [MCPJSONValue],
        _ sourceElementCount: Int,
        _ viewportUpdate: ExcalidrawMCPUpstreamViewportUpdate?,
        _ clientUpdateID: String?
    ) async throws -> PublishedDiagram
    typealias ReadCheckpointElements = @Sendable (_ id: String) async -> [MCPJSONValue]?
    typealias GetAppContext = @Sendable () async throws -> MCPJSONValue
    typealias GetCurrentFile = @Sendable () async throws -> MCPJSONValue
    typealias ListGroups = @Sendable () async throws -> MCPJSONValue
    typealias ListLocalFolders = @Sendable () async throws -> MCPJSONValue
    typealias ListLocalFiles = @Sendable (_ folderID: String?, _ deep: Bool, _ limit: Int) async throws -> MCPJSONValue
    typealias ReadView = @Sendable (_ options: CurrentCanvasOptions) async throws -> MCPJSONValue
    typealias CreateFile = @Sendable (_ name: String?, _ groupID: String?) async throws -> MCPJSONValue
    typealias CreateLocalFile = @Sendable (_ name: String?, _ localFolderID: String) async throws -> MCPJSONValue
    typealias OpenFile = @Sendable (_ fileID: String) async throws -> MCPJSONValue
    typealias OpenLocalFile = @Sendable (_ fileURL: String) async throws -> MCPJSONValue
    typealias SetCanvasPreferences = @Sendable (_ update: CanvasPreferencesSnapshot) async throws -> MCPJSONValue

    var convertRawElements: ElementConverter
    var publishDiagram: PublishDiagram
    var readCheckpointElements: ReadCheckpointElements
    var getAppContext: GetAppContext
    var getCurrentFile: GetCurrentFile
    var listGroups: ListGroups
    var listLocalFolders: ListLocalFolders
    var listLocalFiles: ListLocalFiles
    var readView: ReadView
    var createFile: CreateFile
    var createLocalFile: CreateLocalFile
    var openFile: OpenFile
    var openLocalFile: OpenLocalFile
    var setCanvasPreferences: SetCanvasPreferences
    var appToolAdapters: [String: ExcalidrawMCPLLMCoreToolAdapter] = Dictionary(
        uniqueKeysWithValues: ExcalidrawMCPOptimizedToolCatalog.appToolAdapters.map {
            ($0.exposedName, $0)
        }
    )

    func callTool(
        name: String,
        arguments: [String: MCPJSONValue]
    ) async throws -> ExcalidrawMCPToolResult {
        switch name {
            case ExcalidrawMCPOptimizedContract.ToolName.readMe:
                return ExcalidrawMCPToolResult(text: ExcalidrawMCPOptimizedRecall.guide)

            case ExcalidrawMCPOptimizedContract.ToolName.getAppContext:
                return try await appContext()

            case ExcalidrawMCPOptimizedContract.ToolName.getCurrentFile:
                return try await currentFile()

            case ExcalidrawMCPOptimizedContract.ToolName.listGroups:
                return try await listGroupsTool(arguments: arguments)

            case ExcalidrawMCPOptimizedContract.ToolName.listLocalFolders:
                return try await listLocalFoldersTool(arguments: arguments)

            case ExcalidrawMCPOptimizedContract.ToolName.listLocalFiles:
                return try await listLocalFilesTool(arguments: arguments)

            case ExcalidrawMCPOptimizedContract.ToolName.readView:
                return try await readView(arguments: arguments)

            case ExcalidrawMCPOptimizedContract.ToolName.createFile:
                return try await createFileTool(arguments: arguments)

            case ExcalidrawMCPOptimizedContract.ToolName.createLocalFile:
                return try await createLocalFileTool(arguments: arguments)

            case ExcalidrawMCPOptimizedContract.ToolName.openFile:
                return try await openFileTool(arguments: arguments)

            case ExcalidrawMCPOptimizedContract.ToolName.openLocalFile:
                return try await openLocalFileTool(arguments: arguments)

            case ExcalidrawMCPOptimizedContract.ToolName.setCanvasPreferences:
                return try await setCanvasPreferencesTool(arguments: arguments)

            case ExcalidrawMCPOptimizedContract.ToolName.replaceView:
                return try await replaceView(arguments: arguments)

            default:
                if let adapter = appToolAdapters[name] {
                    return try await adapter.call(arguments: arguments)
                }
                throw MCPJSONRPCError.invalidParams("Unknown tool: \(name)")
        }
    }

    private func appContext() async throws -> ExcalidrawMCPToolResult {
        let context = try await getAppContext()
        return try jsonToolResult(
            value: context,
            fallbackText: "ExcalidrawZ app context is available."
        )
    }

    private func currentFile() async throws -> ExcalidrawMCPToolResult {
        let file = try await getCurrentFile()
        return try jsonToolResult(
            value: file,
            fallbackText: "Current ExcalidrawZ file status is available."
        )
    }

    private func listGroupsTool(arguments: [String: MCPJSONValue]) async throws -> ExcalidrawMCPToolResult {
        let groups = try await listGroups()
        return try jsonToolResult(
            value: groups,
            fallbackText: "ExcalidrawZ library groups are available."
        )
    }

    private func listLocalFoldersTool(arguments: [String: MCPJSONValue]) async throws -> ExcalidrawMCPToolResult {
        let folders = try await listLocalFolders()
        return try jsonToolResult(
            value: folders,
            fallbackText: "ExcalidrawZ local folders are available."
        )
    }

    private func listLocalFilesTool(arguments: [String: MCPJSONValue]) async throws -> ExcalidrawMCPToolResult {
        let files = try await listLocalFiles(
            arguments["local_folder_id"]?.stringValue,
            arguments["deep"]?.boolValue ?? true,
            MCPJSONValue.clampedInteger(arguments["limit"]?.numberValue, default: 100, in: 1...200)
        )
        return try jsonToolResult(
            value: files,
            fallbackText: "ExcalidrawZ local files are available."
        )
    }

    private func readView(arguments: [String: MCPJSONValue]) async throws -> ExcalidrawMCPToolResult {
        let options = CurrentCanvasOptions(
            includeElements: arguments["include_elements"]?.boolValue ?? true,
            includeAppState: arguments["include_app_state"]?.boolValue ?? true,
            includeFiles: arguments["include_files"]?.boolValue ?? false
        )
        let canvas = try await readView(options)
        return try jsonToolResult(
            value: canvas,
            fallbackText: "Current ExcalidrawZ view is available."
        )
    }

    private func createFileTool(arguments: [String: MCPJSONValue]) async throws -> ExcalidrawMCPToolResult {
        if arguments["local_folder_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            throw MCPJSONRPCError.invalidParams("create_file creates library files. Use create_local_file with local_folder_id for local folder files.")
        }
        let file = try await createFile(
            arguments["name"]?.stringValue,
            arguments["group_id"]?.stringValue
        )
        return try jsonToolResult(
            value: .object([
                "file": file,
                "message": .string("Created and opened a new ExcalidrawZ file. You can now call replace_view.")
            ]),
            fallbackText: "Created and opened a new ExcalidrawZ file."
        )
    }

    private func createLocalFileTool(arguments: [String: MCPJSONValue]) async throws -> ExcalidrawMCPToolResult {
        guard let localFolderID = arguments["local_folder_id"]?.stringValue,
              !localFolderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPJSONRPCError.invalidParams("create_local_file requires arguments.local_folder_id.")
        }
        let file = try await createLocalFile(arguments["name"]?.stringValue, localFolderID)
        return try jsonToolResult(
            value: .object([
                "file": file,
                "message": .string("Created and opened a new local Excalidraw file. You can now call replace_view.")
            ]),
            fallbackText: "Created and opened a new local Excalidraw file."
        )
    }

    private func openFileTool(arguments: [String: MCPJSONValue]) async throws -> ExcalidrawMCPToolResult {
        guard let fileID = arguments["file_id"]?.stringValue,
              !fileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPJSONRPCError.invalidParams("open_file requires arguments.file_id.")
        }
        let file = try await openFile(fileID)
        return try jsonToolResult(
            value: .object([
                "file": file,
                "message": .string("Opened the ExcalidrawZ file. You can now call replace_view.")
            ]),
            fallbackText: "Opened the ExcalidrawZ file."
        )
    }

    private func openLocalFileTool(arguments: [String: MCPJSONValue]) async throws -> ExcalidrawMCPToolResult {
        guard let fileURL = arguments["file_url"]?.stringValue,
              !fileURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPJSONRPCError.invalidParams("open_local_file requires arguments.file_url.")
        }
        let file = try await openLocalFile(fileURL)
        return try jsonToolResult(
            value: .object([
                "file": file,
                "message": .string("Opened the local Excalidraw file. You can now call replace_view.")
            ]),
            fallbackText: "Opened the local Excalidraw file."
        )
    }

    private func setCanvasPreferencesTool(arguments: [String: MCPJSONValue]) async throws -> ExcalidrawMCPToolResult {
        let update = try canvasPreferencesUpdate(from: arguments)
        let result = try await setCanvasPreferences(update)
        return try jsonToolResult(
            value: result,
            fallbackText: "Canvas preferences updated."
        )
    }

    private func replaceView(arguments: [String: MCPJSONValue]) async throws -> ExcalidrawMCPToolResult {
        guard let elementsString = arguments["elements"]?.stringValue else {
            throw MCPJSONRPCError.invalidParams("replace_view requires arguments.elements.")
        }
        let clientUpdateID = arguments["client_update_id"]?.stringValue

        let inputData = Data(elementsString.utf8)
        guard inputData.count <= ExcalidrawMCPUpstreamContract.maxInputBytes else {
            return ExcalidrawMCPToolResult(
                text: "Elements input exceeds \(ExcalidrawMCPUpstreamContract.maxInputBytes) byte limit. Reduce the number of elements or use checkpoints to build incrementally.",
                isError: true
            )
        }

        let parsedElements: [MCPJSONValue]
        do {
            parsedElements = try MCPJSONValue.parseJSONArray(from: inputData)
        } catch {
            return ExcalidrawMCPToolResult(
                text: "Invalid JSON in elements. Ensure the value is a JSON array string with no comments or trailing commas.",
                isError: true
            )
        }

        let resolver = ExcalidrawMCPUpstreamElementResolver(
            loadCheckpointElements: readCheckpointElements
        )
        let resolved: ExcalidrawMCPUpstreamElementResolver.Result
        do {
            resolved = try await resolver.resolve(parsedElements)
        } catch let error as ExcalidrawMCPCheckpointNotFoundError {
            return ExcalidrawMCPToolResult(
                text: error.localizedDescription,
                isError: true
            )
        }

        let convertedElements = try await convertRawElements(resolved.elements)
        let published = try await publishDiagram(
            convertedElements,
            parsedElements.count,
            resolved.viewportUpdate,
            clientUpdateID
        )
        let appCheckpointText = appCheckpointSummary(for: published)

        return ExcalidrawMCPToolResult(
            text: """
            View replaced in ExcalidrawZ.
            \(appCheckpointText)
            Next, call read_canvas_image once to inspect the rendered canvas before your final answer.
            If you need App checkpoint ids for current-file history or rollback, call get_current_file_checkpoints.
            """,
            structuredContent: structuredReplaceViewContent(
                published: published,
                clientUpdateID: clientUpdateID
            )
        )
    }

    private func canvasPreferencesUpdate(from arguments: [String: MCPJSONValue]) throws -> CanvasPreferencesSnapshot {
        var update = CanvasPreferencesSnapshot()

        if let rawValue = try stringArgument("theme", in: arguments) {
            guard let value = CanvasPreferencesState.Theme(rawValue: rawValue) else {
                throw MCPJSONRPCError.invalidParams("theme must be one of: light, dark.")
            }
            update.theme = value
        }
        if let value = try stringArgument("viewBackgroundColor", in: arguments) {
            update.viewBackgroundColor = try validatedCanvasColor(
                value,
                key: "viewBackgroundColor"
            )
        }
        if let value = try boolArgument("gridModeEnabled", in: arguments) {
            update.gridModeEnabled = value
        }
        if let value = try boolArgument("zenModeEnabled", in: arguments) {
            update.zenModeEnabled = value
        }
        if let value = try boolArgument("viewModeEnabled", in: arguments) {
            update.viewModeEnabled = value
        }
        if let value = try boolArgument("objectsSnapModeEnabled", in: arguments) {
            update.objectsSnapModeEnabled = value
        }
        if let value = try boolArgument("isMidpointSnappingEnabled", in: arguments) {
            update.isMidpointSnappingEnabled = value
        }
        if let rawValue = try stringArgument("bindingPreference", in: arguments) {
            guard let value = CanvasPreferencesState.BindingPreference(rawValue: rawValue) else {
                throw MCPJSONRPCError.invalidParams("bindingPreference must be one of: enabled, disabled.")
            }
            update.bindingPreference = value
        }
        if let rawValue = try stringArgument("preferredSelectionTool", in: arguments) {
            guard let value = CanvasPreferencesState.PreferredSelectionTool(rawValue: rawValue) else {
                throw MCPJSONRPCError.invalidParams("preferredSelectionTool must be one of: selection, lasso.")
            }
            update.preferredSelectionTool = value
        }
        if let rawValue = try stringArgument("boxSelectionMode", in: arguments) {
            guard let value = CanvasPreferencesState.BoxSelectionMode(rawValue: rawValue) else {
                throw MCPJSONRPCError.invalidParams("boxSelectionMode must be one of: contain, overlap.")
            }
            update.boxSelectionMode = value
        }
        if let value = try boolArgument("stats", in: arguments) {
            update.stats = value
        }

        return update
    }

    private func validatedCanvasColor(_ value: String, key: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^#(?:[0-9A-Fa-f]{3}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$"#
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else {
            throw MCPJSONRPCError.invalidParams(
                "\(key) must be a hex color like #ffffff, #fff, or #1e1e2eff."
            )
        }
        return trimmed
    }

    private func stringArgument(
        _ key: String,
        in arguments: [String: MCPJSONValue]
    ) throws -> String? {
        guard let value = arguments[key] else { return nil }
        guard let string = value.stringValue else {
            throw MCPJSONRPCError.invalidParams("\(key) must be a string.")
        }
        return string
    }

    private func boolArgument(
        _ key: String,
        in arguments: [String: MCPJSONValue]
    ) throws -> Bool? {
        guard let value = arguments[key] else { return nil }
        guard case .bool(let bool) = value else {
            throw MCPJSONRPCError.invalidParams("\(key) must be a boolean.")
        }
        return bool
    }

    private func appCheckpointSummary(for published: PublishedDiagram) -> String {
        let hasAppCheckpoint = published.appPreCheckpointID != nil || published.appPostCheckpointID != nil
        if !hasAppCheckpoint {
            return published.appCheckpointWarning ?? "App file-history checkpoints: unavailable for this target."
        }
        if let warning = published.appCheckpointWarning {
            return "App file-history checkpoints recorded. Call get_current_file_checkpoints to retrieve their ids. \(warning)"
        }
        return "App file-history checkpoints recorded. Call get_current_file_checkpoints to retrieve their ids."
    }

    private func structuredReplaceViewContent(
        published: PublishedDiagram,
        clientUpdateID: String?
    ) -> MCPJSONValue {
        var object: [String: MCPJSONValue] = [:]
        if let clientUpdateID {
            object["clientUpdateId"] = .string(clientUpdateID)
        }
        let hasAppCheckpoint = published.appPreCheckpointID != nil || published.appPostCheckpointID != nil
        let appCheckpointStatus = hasAppCheckpoint ? "recorded" : "unavailable"
        object["appFileHistoryCheckpointStatus"] = .string(appCheckpointStatus)
        if let warning = published.appCheckpointWarning {
            object["appCheckpointWarning"] = .string(warning)
        }
        return .object(object)
    }

    private func jsonToolResult(
        value: MCPJSONValue,
        fallbackText: String
    ) throws -> ExcalidrawMCPToolResult {
        let data = try value.mcpJSONData()
        let text = String(data: data, encoding: .utf8) ?? fallbackText
        return ExcalidrawMCPToolResult(
            text: text,
            structuredContent: value
        )
    }
}

private extension MCPJSONValue {
    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }
}
