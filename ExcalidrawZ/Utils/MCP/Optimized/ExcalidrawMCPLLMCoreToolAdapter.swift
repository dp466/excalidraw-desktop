//
//  ExcalidrawMCPLLMCoreToolAdapter.swift
//  ExcalidrawZ
//
//  Created by Codex on 2026/06/16.
//

import Foundation
import LLMCore

struct ExcalidrawMCPLLMCoreToolAdapter: Sendable {
    typealias ContextProvider = @Sendable () async throws -> (any ChatInvocationContext)?
    typealias ArgumentNormalizer = @Sendable ([String: MCPJSONValue]) async throws -> [String: MCPJSONValue]

    let tool: any Tool
    let exposedName: String
    let title: String
    let description: String
    let schemaOverride: MCPJSONValue?
    let annotations: [String: MCPJSONValue]
    let contextProvider: ContextProvider
    let normalizeArguments: ArgumentNormalizer
    let mutationCheckpointDescription: String?

    init(
        tool: any Tool,
        exposedName: String? = nil,
        title: String? = nil,
        description: String? = nil,
        schemaOverride: MCPJSONValue? = nil,
        annotations: [String: MCPJSONValue] = [:],
        contextProvider: @escaping ContextProvider = { nil },
        normalizeArguments: @escaping ArgumentNormalizer = { $0 },
        mutationCheckpointDescription: String? = nil
    ) {
        let resolvedName = exposedName ?? tool.name
        self.tool = tool
        self.exposedName = resolvedName
        self.title = title ?? tool.displayName
        self.description = description ?? ExcalidrawMCPOptimizedResources.description(
            named: resolvedName,
            fallback: tool.description
        )
        self.schemaOverride = schemaOverride
            ?? ExcalidrawMCPOptimizedResources.schemaIfAvailable(named: resolvedName)
            ?? Self.resolvedSchema(from: tool.inputSchema)
            ?? ExcalidrawMCPOptimizedResources.fallbackSchema(named: resolvedName)
        self.annotations = annotations
        self.contextProvider = contextProvider
        self.normalizeArguments = normalizeArguments
        self.mutationCheckpointDescription = mutationCheckpointDescription
    }

    private static func resolvedSchema(from inputSchema: ToolInputSchema) -> MCPJSONValue? {
        guard let resolved = try? inputSchema.resolve(),
              let data = try? JSONEncoder().encode(resolved) else {
            return nil
        }
        return try? MCPJSONValue.parse(from: data)
    }

    var mcpTool: ExcalidrawMCPTool {
        ExcalidrawMCPTool(
            name: exposedName,
            title: title,
            description: description,
            inputSchema: schemaOverride ?? ExcalidrawMCPToolSchemas.emptyObject,
            annotations: annotations
        )
    }

    func call(arguments: [String: MCPJSONValue]) async throws -> ExcalidrawMCPToolResult {
        do {
            let normalizedArguments = try await normalizeArguments(arguments)
            let inputData = try MCPJSONValue.object(normalizedArguments).mcpJSONData()
            guard let input = String(data: inputData, encoding: .utf8) else {
                throw MCPJSONRPCError.invalidParams("Tool arguments must be valid UTF-8 JSON.")
            }

            if let mutationCheckpointDescription,
               !Self.requestsDryRun(normalizedArguments) {
                let checkpointed = try await ExcalidrawMCPAppBridge.shared.optimizedMutationWithCheckpoints(
                    description: mutationCheckpointDescription
                ) {
                    let result = try await executeLocalMCPTool(input: input)
                    return Self.mcpResult(from: result)
                }
                return Self.mcpResultWithCheckpointSummary(
                    checkpointed.result,
                    preCheckpointID: checkpointed.preCheckpointID,
                    postCheckpointID: checkpointed.postCheckpointID,
                    warning: checkpointed.checkpointWarning
                )
            }

            let result = try await executeLocalMCPTool(input: input)
            return Self.mcpResult(from: result)
        } catch {
            return ExcalidrawMCPToolResult(
                text: error.localizedDescription,
                isError: true
            )
        }
    }

    private func executeLocalMCPTool(input: String) async throws -> ToolResult {
        let context = try await contextProvider()
        return try await AIChatToolExecutionGate.withLocalMCPExecution {
            try await tool.execute(input, context: context)
        }
    }

    private static func requestsDryRun(_ arguments: [String: MCPJSONValue]) -> Bool {
        let value = arguments["dryRun"] ?? arguments["dry_run"]
        guard case .bool(let isDryRun) = value else {
            return false
        }
        return isDryRun
    }

    private static func mcpResult(from result: ToolResult) -> ExcalidrawMCPToolResult {
        let content = mcpContent(from: result)
        let text = result.textObservation
        if text.isEmpty {
            return ExcalidrawMCPToolResult(
                content: content.isEmpty ? [.text("ok")] : content
            )
        }

        let structuredContent: MCPJSONValue? = {
            guard let data = text.data(using: .utf8),
                  let value = try? MCPJSONValue.parse(from: data) else {
                return nil
            }
            return value
        }()

        if let structuredContent,
           let exportedResult = exportedArtifactResult(
            from: structuredContent,
            fallbackText: text
           ) {
            return exportedResult
        }

        return ExcalidrawMCPToolResult(
            content: content.isEmpty ? [.text(text)] : content,
            structuredContent: structuredContent
        )
    }

    private static func mcpResultWithCheckpointSummary(
        _ result: ExcalidrawMCPToolResult,
        preCheckpointID: UUID?,
        postCheckpointID: UUID?,
        warning: String?
    ) -> ExcalidrawMCPToolResult {
        let hasCheckpoint = preCheckpointID != nil || postCheckpointID != nil
        let status = hasCheckpoint ? "recorded" : "unavailable"
        let summary = if hasCheckpoint {
            "App file-history checkpoints recorded. Call get_current_file_checkpoints to retrieve their ids."
        } else {
            "App file-history checkpoints unavailable for this target."
        }

        var content = result.content
        content.append(.text(warning.map { "\(summary) \($0)" } ?? summary))

        var checkpointContent: [String: MCPJSONValue] = [
            "appFileHistoryCheckpointStatus": .string(status)
        ]
        if let warning {
            checkpointContent["appCheckpointWarning"] = .string(warning)
        }
        let structuredContent = mergedStructuredContent(
            result.structuredContent,
            with: checkpointContent
        )

        return ExcalidrawMCPToolResult(
            content: content,
            isError: result.isError,
            structuredContent: structuredContent
        )
    }

    private static func mergedStructuredContent(
        _ value: MCPJSONValue?,
        with additions: [String: MCPJSONValue]
    ) -> MCPJSONValue {
        if case .object(var object) = value {
            for (key, addition) in additions {
                object[key] = addition
            }
            return .object(object)
        }
        return .object(additions)
    }

    private static func mcpContent(from result: ToolResult) -> [ExcalidrawMCPToolResult.Content] {
        switch result {
            case .text(let text):
                return [.text(text)]
            case .parts(let parts):
                return parts.flatMap { part -> [ExcalidrawMCPToolResult.Content] in
                    switch part {
                        case .text(let text):
                            return [.text(text)]
                        case .image(.data(let data, let mediaType)):
                            return [
                                .image(
                                    data: data.base64EncodedString(),
                                    mimeType: mediaType
                                )
                            ]
                        case .image(.url(let url)):
                            return imageContent(from: url) ?? [
                                .text("Image URL: \(url.absoluteString)")
                            ]
                    }
                }
        }
    }

    private static func exportedArtifactResult(
        from value: MCPJSONValue,
        fallbackText: String
    ) -> ExcalidrawMCPToolResult? {
        guard case .object(var object) = value,
              let mimeType = object["mimeType"]?.stringValue,
              let rawURL = object["url"]?.stringValue,
              let url = localFileURL(from: rawURL),
              let data = try? Data(contentsOf: url) else {
            return nil
        }

        let resourceURI = "resource://excalidrawz/canvas/\(UUID().uuidString).\(url.pathExtension)"
        let fileName = object["fileName"]?.stringValue ?? url.lastPathComponent
        let message = object["message"]?.stringValue ?? fallbackText
        object["uri"] = .string(resourceURI)
        object["sizeBytes"] = .number(Double(data.count))
        object.removeValue(forKey: "url")

        let artifactContent: ExcalidrawMCPToolResult.Content = if mimeType.hasPrefix("image/") {
            .image(
                data: data.base64EncodedString(),
                mimeType: mimeType
            )
        } else {
            .resource(
                uri: resourceURI,
                mimeType: mimeType,
                blob: data.base64EncodedString()
            )
        }

        return ExcalidrawMCPToolResult(
            content: [
                .text("\(message) \(fileName) (\(data.count) bytes)."),
                artifactContent
            ],
            structuredContent: .object(object)
        )
    }

    private static func localFileURL(from value: String) -> URL? {
        let url: URL
        if let parsed = URL(string: value), parsed.isFileURL {
            url = parsed
        } else if value.hasPrefix("/") {
            url = URL(fileURLWithPath: value)
        } else {
            return nil
        }
        return isToolArtifact(url) ? url : nil
    }

    /// Tool outputs are JSON that can echo document data. Attach only files the
    /// tools wrote to the temporary directory, never another local path.
    static func isToolArtifact(_ url: URL) -> Bool {
        let root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func imageContent(from url: URL) -> [ExcalidrawMCPToolResult.Content]? {
        guard url.isFileURL,
              isToolArtifact(url),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return [
            .image(
                data: data.base64EncodedString(),
                mimeType: mimeType(for: url) ?? "image/png"
            )
        ]
    }

    private static func mimeType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
            case "png":
                return "image/png"
            case "jpg", "jpeg":
                return "image/jpeg"
            case "gif":
                return "image/gif"
            case "webp":
                return "image/webp"
            case "svg":
                return "image/svg+xml"
            default:
                return nil
        }
    }
}
