import Foundation

extension ExcalidrawMCPAppBridge {
    /// Capture one addressed editor, rather than resolving a global "current"
    /// coordinator again after suspension. Raw scene fields survive embedding.
    @MainActor
    func fullExportDiagram(arguments: [String: MCPJSONValue]) async throws -> MCPJSONValue {
        guard let documentID = arguments["document_id"]?.stringValue else {
            throw MCPJSONRPCError.invalidParams("document_id is required.")
        }
        let (state, core) = try await requireMCPDocument(documentID: documentID, requiresMutation: false)
        guard state.beginDiagramAutomation(documentID: documentID) else {
            throw ExcalidrawMCPCommandError(code: "editor_busy", message: "Wait for the document switch or save to finish before exporting.")
        }
        defer { state.endDiagramAutomation() }
        let persistence = try await saveMCPDocument(documentID: documentID)
        let before = try await core.performDiagramCommand(["action": .string("inspect"), "document_id": .string(documentID), "limit": .number(1)])
        let snapshot = try await core.getCurrentFileSnapshot()
        let after = try await core.performDiagramCommand(["action": .string("inspect"), "document_id": .string(documentID), "limit": .number(1)])
        guard before["revision"] == after["revision"], state.currentActiveFile?.id == documentID else {
            throw ExcalidrawMCPCommandError(code: "revision_conflict", message: "The diagram changed while capturing the export. Retry to capture its new revision.")
        }
        let sceneData = try snapshot.documentData()
        let scene = try MCPJSONValue.parse(from: sceneData)
        let kind = arguments["kind"]?.stringValue ?? "file"
        let format = kind == "file" ? "excalidraw" : kind == "pdf" ? "pdf" : arguments["format"]?.stringValue ?? "png"
        let base = state.currentActiveFile?.name ?? "Diagram"
        let editable = arguments["editable"] == .bool(true)
        let data: Data
        if kind == "file" { data = sceneData }
        else {
            let payload = String(decoding: try MCPJSONValue.object([
                "scene": scene, "format": .string(format), "editable": .bool(editable),
                "background": .bool(arguments["with_background"] != .bool(false)),
                "dark": .bool(arguments["color_scheme"] == .string("dark")),
                "scale": arguments["export_scale"] ?? .number(1)
            ]).mcpJSONData(), as: UTF8.self)
            let raw = try await core.webView.callAsyncJavaScript(
                """
                const p = JSON.parse(payload), h = window.excalidrawZHelper;
                await document.fonts.ready;
                if (p.format === "png") {
                    const result = await h.exportElementsToBlob(p.scene.elements, p.scene.files, {
                        exportEmbedScene: p.editable, withBackground: p.background,
                        exportWithDarkMode: p.dark, mimeType: "image/png", exportScale: p.scale
                    });
                    return JSON.stringify({data: result.blobData});
                }
                const result = await h.exportElementsToSvg(p.scene.elements, p.scene.files,
                    p.editable, p.background, p.dark);
                return JSON.stringify({svg: result.svg});
                """, arguments: ["payload": payload], contentWorld: .page)
            guard let text = raw as? String else { throw ExcalidrawCore.InvalidJavaScriptResult() }
            let result = try MCPJSONValue.parse(from: Data(text.utf8))
            if format == "png", let bytes = result["data"]?.stringValue.flatMap({ Data(base64Encoded: $0) }) { data = bytes }
            else if let svg = result["svg"]?.stringValue {
                let svgData = Data(svg.utf8)
                if format == "pdf" {
                    let temporaryDirectory = try getTempDirectory()
                    let temporary = temporaryDirectory.appendingPathComponent(UUID().uuidString + ".svg")
                    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
                    try svgData.write(to: temporary, options: .atomic)
                    data = try await renderPDFData(from: temporary, filename: base)
                } else { data = svgData }
            } else { throw ExcalidrawMCPCommandError(code: "export_failed", message: "The editor returned no export data.") }
        }
        try Task.checkCancellation()
        let suffix = editable && kind == "image" ? "excalidraw." + format : format
        let safeName = base.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r")).joined(separator: "_")
        let filename = (safeName.isEmpty ? "Diagram" : safeName) + "." + suffix
        // itemReplacementDirectory creates macOS NSIRD folders that other
        // applications cannot read. MCP artifacts must be usable by the client
        // process, so keep them in the user's ordinary temporary directory.
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ExcalidrawDesktop-MCP-Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(UUID().uuidString + "-" + filename)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let mime = ["png": "image/png", "svg": "image/svg+xml", "pdf": "application/pdf", "excalidraw": "application/vnd.excalidraw+json"][format] ?? "application/octet-stream"
        let elements = scene["elements"]?.arrayValue ?? []
        let visibleCount = elements.filter { $0["isDeleted"] != MCPJSONValue.bool(true) }.count
        let output: [String: MCPJSONValue] = ["document_id": .string(documentID), "revision": after["revision"] ?? .null,
                        "persistence": persistence, "kind": .string(kind), "format": .string(format),
                        "fileName": .string(filename), "url": .string(url.absoluteString),
                        "mimeType": .string(mime), "sizeBytes": .number(Double(data.count)),
                        "elementCount": .number(Double(visibleCount))]
        return .object(output)
    }
}
