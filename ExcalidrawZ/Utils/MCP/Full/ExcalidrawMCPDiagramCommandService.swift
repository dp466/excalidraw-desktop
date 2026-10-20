import Foundation
import CryptoKit

/// Serializes native and compatibility calls across suspension points. The editor
/// additionally uses CAS immediately before its single scene commit.
actor ExcalidrawMCPDiagramCommandService {
    static let shared = ExcalidrawMCPDiagramCommandService()
    private var tail: Task<Void, Never>?
    private struct Receipt: Codable, Sendable {
        let fingerprint: String
        var result: MCPJSONValue?
        /// Absent in receipts written before build 140; those are trimmed first.
        var createdAt: Date? = nil
    }
    /// Every mutation stores its full result (images included) and the whole
    /// file is rewritten twice per call. Request IDs protect retries, which
    /// follow shortly after the original call; keep the newest receipts only.
    static let maximumReceiptCount = 256
    private var receipts: [String: Receipt] = [:]
    private var didLoadReceipts = false
    private let receiptURL: URL
    private let executor: (@Sendable (String, [String: MCPJSONValue], String) async throws -> ExcalidrawMCPToolResult)?

    init(receiptURL: URL? = nil, executor: (@Sendable (String, [String: MCPJSONValue], String) async throws -> ExcalidrawMCPToolResult)? = nil) {
        self.executor = executor
        let testingURL = AppRuntime.isRunningTests ? FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-test-receipts-" + UUID().uuidString + ".json") : nil
        self.receiptURL = receiptURL ?? testingURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.dparadis.ExcalidrawDesktop", isDirectory: true)
            .appendingPathComponent("MCP", isDirectory: true).appendingPathComponent("receipts.json")
    }

    private func loadReceipts() throws {
        guard !didLoadReceipts else { return }
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            receipts = try JSONDecoder().decode([String: Receipt].self, from: Data(contentsOf: receiptURL))
        }
        didLoadReceipts = true
    }

    private func persistReceipts() throws {
        try FileManager.default.createDirectory(at: receiptURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(receipts).write(to: receiptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
    }

    private func trimReceipts(keeping key: String) {
        let excess = receipts.count - Self.maximumReceiptCount
        guard excess > 0 else { return }
        let oldest = receipts
            .filter { $0.key != key }
            .sorted { ($0.value.createdAt ?? .distantPast) < ($1.value.createdAt ?? .distantPast) }
            .prefix(excess)
        for (staleKey, _) in oldest { receipts.removeValue(forKey: staleKey) }
    }

    func performExclusive<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let previous = tail
        let work = Task {
            await previous?.value
            try Task.checkCancellation()
            return try await operation()
        }
        tail = Task { _ = await work.result }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    func callTool(name: String, arguments: [String: MCPJSONValue], clientID: String) async throws -> ExcalidrawMCPToolResult {
        try await performExclusive { [self] in
            try await execute(name: name, arguments: arguments, clientID: clientID)
        }
    }

    private func execute(name: String, arguments: [String: MCPJSONValue], clientID: String) async throws -> ExcalidrawMCPToolResult {
        if let tool = ExcalidrawMCPFullToolCatalog.tools.first(where: { $0.name == name }) {
            try MCPJSONSchemaValidator.validate(.object(arguments), schema: tool.inputSchema)
        }
        let mutating = ExcalidrawMCPFullToolCatalog.isMutation(name: name, arguments: arguments)
        let dryRun = arguments["dry_run"] == .bool(true)
        let requestID = arguments["request_id"]?.stringValue
        let key = requestID.map { clientID + "\u{0}" + $0 }
        let fingerprint = SHA256.hash(data: try MCPJSONValue.object([
            "tool": .string(name), "arguments": .object(arguments)
        ]).mcpJSONData()).map { String(format: "%02x", $0) }.joined()
        if mutating && !dryRun {
            try loadReceipts()
            guard let requestID, !requestID.isEmpty, requestID.count <= 256 else {
                return Self.failure(code: "invalid_request_id", message: "Mutations require a request_id (1–256 characters).")
            }
            if let key, let receipt = receipts[key] {
                guard receipt.fingerprint == fingerprint else {
                    return Self.failure(code: "request_id_conflict", message: "This client already used request_id with different arguments.")
                }
                guard let result = receipt.result else {
                    return Self.failure(code: "request_outcome_unknown", message: "This request was interrupted. Inspect the document or library before issuing a new request; it will not be repeated automatically.")
                }
                return Self.replay(result)
            }
            if let key {
                receipts[key] = Receipt(fingerprint: fingerprint, result: nil, createdAt: Date())
                trimReceipts(keeping: key)
                do { try persistReceipts() }
                catch { receipts.removeValue(forKey: key); throw error }
            }
        }
        let result: ExcalidrawMCPToolResult
        do {
            if let executor { result = try await executor(name, arguments, clientID) }
            else { result = try await Self.executeNative(name: name, arguments: arguments, clientID: clientID) }
        } catch let error as ExcalidrawMCPCommandError {
            result = Self.failure(code: error.code, message: error.message, details: error.details)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            result = Self.failure(code: "command_failed", message: error.localizedDescription)
        }
        // Record errors too: changing arguments always requires a new request ID.
        // A write-ahead pending receipt prevents replay after a process crash.
        if mutating && !dryRun, let key {
            receipts[key] = Receipt(fingerprint: fingerprint, result: result.jsonValue, createdAt: receipts[key]?.createdAt ?? Date())
            do { try persistReceipts() }
            catch {
                // Keep the result in memory. The disk's pending marker still blocks
                // re-execution after restart if the final receipt could not save.
                var object = result.structuredContent?.objectValue ?? [:]
                object["receipt_warning"] = .string("The outcome is known in this process but its durable receipt could not be saved.")
                return ExcalidrawMCPToolResult(content: result.content, isError: result.isError, structuredContent: .object(object))
            }
        }
        return result
    }

    @MainActor
    private static func executeNative(name: String, arguments: [String: MCPJSONValue], clientID: String) async throws -> ExcalidrawMCPToolResult {
        let bridge = ExcalidrawMCPAppBridge.shared
        bridge.mcpAllowsHostedAICommand = clientID == "hosted-ai"
        defer { bridge.mcpAllowsHostedAICommand = false }
        let documentID = arguments["document_id"]?.stringValue
        // Metadata commands may address a closed file. Only save needs a mounted
        // canvas; the native document service verifies all storage permissions.
        let isOpening = name == "document_command" && arguments["action"] != .string("save")
        let metadataMutation = isOpening && ["rename", "duplicate", "move", "trash"].contains(arguments["action"]?.stringValue ?? "")
        let mounted = bridge.mcpOpenWindows().arrayValue?.contains { $0["document_id"]?.stringValue == documentID } == true
        let targetID = isOpening && !(metadataMutation && mounted) ? nil : documentID
        try bridge.selectMCPWindow(documentID: targetID, windowID: arguments["window_id"]?.stringValue)
        defer { bridge.clearMCPWindow() }
        try Task.checkCancellation()
        switch name {
        case "read_me":
            return ExcalidrawMCPToolResult(text: ExcalidrawMCPFullToolCatalog.instructions)
        case "get_app_context":
            var result = (await bridge.optimizedAppContext()).objectValue ?? [:]
            result["serviceMode"] = .string("full")
            result["windows"] = bridge.mcpOpenWindows()
            return response(.object(result))
        case "get_capabilities":
            var result = ExcalidrawMCPFullToolCatalog.capabilities.objectValue ?? [:]
            result["windows"] = bridge.mcpOpenWindows()
            if let state = bridge.mcpFileState, let id = state.currentActiveFile?.id,
               let (_, core) = try? await bridge.requireMCPDocument(documentID: id, requiresMutation: false) {
                result["engine"] = try await core.performDiagramCommand(["action": .string("get_capabilities"), "document_id": .string(id)])
            }
            return response(.object(result))
        case "document_command":
            return response(try await bridge.fullDocumentCommand(arguments: arguments))
        case "library_command" where arguments["action"] != .string("insert"):
            return response(try await bridge.fullLibraryCommand(arguments: arguments))
        case "presentation_command":
            return response(try await bridge.fullPresentationCommand(arguments: arguments))
        case "export_diagram":
            return response(try await bridge.fullExportDiagram(arguments: arguments))
        case "checkpoint_command" where arguments["action"] != .string("restore"):
            return response(try await bridge.fullCheckpointCommand(arguments: arguments))
        default: break
        }
        guard let documentID, !documentID.isEmpty else {
            throw MCPJSONRPCError.invalidParams("document_id is required; read get_app_context first.")
        }
        let mutating = ExcalidrawMCPFullToolCatalog.isMutation(name: name, arguments: arguments)
        let (state, core) = try await bridge.requireMCPDocument(documentID: documentID, requiresMutation: mutating)
        if mutating, !state.beginDiagramAutomation(documentID: documentID) {
            throw ExcalidrawMCPCommandError(code: "editor_busy", message: "The document is being switched, saved or closed. Retry after that operation finishes.")
        }
        defer { if mutating { state.endDiagramAutomation() } }
        var payload = arguments
        payload["client_id"] = .string(clientID)
        payload["action"] = .string(name == "read_diagram" ? "inspect" : name)
        if name == "library_command" {
            let prepared = try await bridge.fullLibraryCommand(arguments: arguments)
            guard let elements = prepared["prepared_elements"] else { throw MCPJSONRPCError.internalError("Library insertion failed to prepare elements.") }
            payload["action"] = .string("apply_operations")
            payload["operations"] = .array([.object(["type": .string("create"), "elements": elements, "raw": .bool(true)])])
            payload["files"] = prepared["files"]
        } else if name == "checkpoint_command" {
            let scene = try await bridge.fullCheckpointScene(arguments: arguments)
            payload["action"] = .string("apply_operations")
            payload["operations"] = .array([.object([
                "type": .string("replace_scene"), "elements": scene["elements"] ?? .array([]),
                "files": scene["files"] ?? .object([:]), "app_state": scene["appState"] ?? .object([:])
            ])])
        }
        if mutating {
            guard let expected = arguments["expected_revision"]?.stringValue, !expected.isEmpty else {
                throw MCPJSONRPCError.invalidParams("expected_revision is required; read_diagram returns it.")
            }
        }
        if name == "history" { payload["operation"] = arguments["operation"] }
        var preCheckpoint: String?
        if mutating && arguments["dry_run"] != .bool(true) {
            // Validate revision BEFORE writing even a history checkpoint.
            let current = try await core.performDiagramCommand(["action": .string("inspect"), "document_id": .string(documentID), "limit": .number(1)])
            guard current["revision"] == arguments["expected_revision"] else {
                throw ExcalidrawMCPCommandError(code: "revision_conflict", message: "The diagram changed. Read it again before applying edits.", details: current["revision"])
            }
            preCheckpoint = try await bridge.fullMCPCheckpoint(documentID: documentID, description: "Before MCP \(name)", before: true)
        }
        // Do not drop this checkpoint on a later failure: it is the recovery path.
        let originalSuppression = state.mcpCheckpointSuppressionDepth
        if mutating { state.mcpCheckpointSuppressionDepth += 1 }
        defer { state.mcpCheckpointSuppressionDepth = originalSuppression }
        payload = try await ExcalidrawMCPAssetPreparation.prepare(payload)
        var value = try await core.performDiagramCommand(payload)
        if var object = value.objectValue, let preCheckpoint { object["pre_checkpoint_id"] = .string(preCheckpoint); value = .object(object) }
        if mutating && arguments["dry_run"] != .bool(true) {
            var object = value.objectValue ?? [:]
            do {
                let persistence = try await bridge.saveMCPDocument(documentID: documentID)
                object["persistence"] = persistence
                object["post_checkpoint_id"] = .string(try await bridge.fullMCPCheckpoint(documentID: documentID, description: "MCP \(name)", before: false))
            } catch {
                object["persistence"] = .object(["status": .string("failed"), "message": .string(error.localizedDescription)])
                object["warning"] = .string("The canvas changed; saving or the post-checkpoint failed. Retry document_command save, not the edit.")
            }
            value = .object(object)
        }
        return response(value)
    }

    static func response(_ value: MCPJSONValue) -> ExcalidrawMCPToolResult {
        var content: [ExcalidrawMCPToolResult.Content] = []
        var metadata = value.objectValue ?? ["result": value]
        let libraryImage: MCPJSONValue? = metadata["mimeType"] == .string("image/png") ? .object(["data": metadata["data"] ?? .null, "mime_type": .string("image/png")]) : nil
        let image = metadata["image"] ?? value["result"]?["image"] ?? libraryImage
        if let data = image?["data"]?.stringValue {
            content.append(.image(data: data, mimeType: image?["mime_type"]?.stringValue ?? "image/png"))
            metadata.removeValue(forKey: "image")
            if libraryImage != nil { metadata.removeValue(forKey: "data") }
            if var result = metadata["result"]?.objectValue { result.removeValue(forKey: "image"); metadata["result"] = .object(result) }
        }
        let structured = MCPJSONValue.object(metadata)
        let text = (try? structured.mcpJSONData()).map { String(decoding: $0, as: UTF8.self) } ?? "ok"
        content.insert(.text(text), at: 0)
        return ExcalidrawMCPToolResult(content: content, structuredContent: structured)
    }

    static func failure(code: String, message: String, details: MCPJSONValue? = nil) -> ExcalidrawMCPToolResult {
        let value = MCPJSONValue.object(["ok": .bool(false), "error": .object([
            "code": .string(code), "message": .string(message), "details": details ?? .null
        ])])
        return ExcalidrawMCPToolResult(text: message, isError: true, structuredContent: value)
    }

    private static func replay(_ value: MCPJSONValue) -> ExcalidrawMCPToolResult {
        let content = (value["content"]?.arrayValue ?? []).compactMap { item -> ExcalidrawMCPToolResult.Content? in
            if item["type"] == .string("text"), let text = item["text"]?.stringValue { return .text(text) }
            if item["type"] == .string("image"), let data = item["data"]?.stringValue {
                return .image(data: data, mimeType: item["mimeType"]?.stringValue ?? "image/png")
            }
            if item["type"] == .string("resource"), let resource = item["resource"],
               let uri = resource["uri"]?.stringValue, let blob = resource["blob"]?.stringValue {
                return .resource(uri: uri, mimeType: resource["mimeType"]?.stringValue ?? "application/octet-stream", blob: blob)
            }
            return nil
        }
        return ExcalidrawMCPToolResult(content: content, isError: value["isError"] == .bool(true), structuredContent: value["structuredContent"])
    }
}
