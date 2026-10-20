//
//  ReadCanvasImageTool.swift
//  ExcalidrawZ
//

import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import LLMCore

/// Take a PNG snapshot of the current Excalidraw canvas and return it as a
/// multimodal tool result (text caption + image). The image goes to the
/// vision model natively — pair with `read_file` (structural element data)
/// when you need to *see* the canvas: layout, hand-drawn detail, colors, or
/// any visual quality the structural read can't capture.
struct ReadCanvasImageTool: Tool {
    struct ReadCanvasImageContext: ToolContext {
        var canvasTarget: ExcalidrawCoordinatorRegistry.CanvasTarget
        var readCanvasTarget: ExcalidrawCoordinatorRegistry.CanvasTarget?
        var currentModelSupportsImageInput: Bool?
        var currentFileID: UUID? = nil
        var isCurrentFileContextProtected: Bool = false
    }

    var name: String { "read_canvas_image" }

    var displayName: String { String(localizable: .aiChatToolReadCanvasImageName) }

    var description: String {
        """
        Take a PNG snapshot of the current Excalidraw file when file context
        is available and return it as an image. Use this when you need to
        visually inspect the canvas: layout, spatial relationships, hand-drawn
        details, colors, or anything the structural `read_file` tool cannot
        capture. Defaults to the current visible viewport so it matches what
        the user is currently looking at. Set `scope` to `full` only when you
        need a whole-canvas overview beyond the visible viewport.
        """
    }

    var inputSchema: ToolInputSchema {
        .parameters(ToolParameters(
            properties: [
                "scope": ParameterProperty(
                    type: "string",
                    description: "Image capture scope. Defaults to viewport for ordinary visual checks; use full only for a whole-canvas overview.",
                    enum: ["viewport", "full"]
                )
            ],
            required: []
        ))
    }

    func execute(_ input: String, context: (any ChatInvocationContext)?) async throws -> ToolResult {
        try AIChatToolExecutionGate.ensureAIEnabled()
        let params = try parseInput(input)
        let scope = params.scope ?? .viewport

        guard let context else {
            throw ToolError.executionFailed("Missing ReadCanvasImageContext")
        }
        let canvasContext = try context.resolve(ReadCanvasImageContext.self)
        guard !canvasContext.isCurrentFileContextProtected else {
            return LockedContentAIGuard.lockedToolResult
        }
        guard try await LockedContentAIGuard.canToolAccess(fileID: canvasContext.currentFileID) else {
            return LockedContentAIGuard.lockedToolResult
        }

        guard canvasContext.currentModelSupportsImageInput ?? true else {
            return .text("The current model cannot read image tool results. Use read_file for structural canvas data instead.")
        }

        let canvasTarget = canvasContext.readCanvasTarget ?? canvasContext.canvasTarget
        let coordinator = try await ExcalidrawCoordinatorRegistry.shared.resolvedCoordinator(for: canvasTarget)
        guard let coordinator else {
            throw ToolError.executionFailed("Missing active Excalidraw coordinator")
        }

        let elementCount = await MainActor.run {
            coordinator.parent?.file?.elements.filter { !$0.isDeleted }.count ?? 0
        }

        if elementCount == 0 {
            return .text("Canvas is empty — nothing to capture.")
        }

        let preferences = try? await coordinator.fetchCanvasPreferences()
        let export = try await exportImage(
            scope: scope,
            coordinator: coordinator,
            preferences: preferences
        )
        let pngData = CanvasImageToolImageBounds.boundedPNG(export.data)
        let caption = caption(
            scope: scope,
            elementCount: elementCount,
            export: export.metadata,
            preferences: preferences
        )
        return .parts([
            .text(caption),
            .image(.data(pngData, mediaType: "image/png"))
        ])
    }
}

private extension ReadCanvasImageTool {
    struct Input: Decodable {
        var scope: Scope? = nil
    }

    enum Scope: String, Decodable {
        case viewport
        case full
    }

    struct ExportedImage {
        var data: Data
        var metadata: ExcalidrawCore.ViewportImageExportResult?
    }

    func parseInput(_ input: String) throws -> Input {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Input() }
        guard let data = trimmed.data(using: .utf8) else {
            throw ToolError.invalidInput("Expected JSON object.")
        }
        do {
            return try JSONDecoder().decode(Input.self, from: data)
        } catch {
            throw ToolError.invalidInput("Expected read_canvas_image parameters JSON object: \(error.localizedDescription)")
        }
    }

    func exportImage(
        scope: Scope,
        coordinator: ExcalidrawCanvasView.Coordinator,
        preferences: CanvasPreferencesSnapshot?
    ) async throws -> ExportedImage {
        do {
            switch scope {
                case .viewport:
                    let result = try await coordinator.exportCurrentViewportToPNGData()
                    return ExportedImage(data: result.data, metadata: result)
                case .full:
                    guard let file = await coordinator.parent?.file else {
                        throw ToolError.executionFailed("No active file to export.")
                    }
                    let data = try await coordinator.exportElementsToPNGData(
                        elements: file.elements,
                        files: file.files,
                        colorScheme: Self.colorScheme(from: preferences?.theme)
                    )
                    return ExportedImage(data: data, metadata: nil)
            }
        } catch let error as ToolError {
            throw error
        } catch {
            throw ToolError.executionFailed("Failed to export canvas: \(error.localizedDescription)")
        }
    }

    func caption(
        scope: Scope,
        elementCount: Int,
        export: ExcalidrawCore.ViewportImageExportResult?,
        preferences: CanvasPreferencesSnapshot?
    ) -> String {
        var parts: [String] = [
            scope == .viewport ? "Canvas viewport snapshot." : "Canvas full overview snapshot.",
            "fileElements=\(elementCount).",
            "renderedTheme=\(Self.themeDescription(preferences?.theme)).",
            "viewBackgroundColor=\(preferences?.viewBackgroundColor ?? "unknown")."
        ]

        if let export {
            parts.insert(
                "exportedElements=\(export.elementCount.map { String($0) } ?? "unknown").",
                at: 2
            )
            parts.insert(
                "size=\(Self.sizeDescription(width: export.width, height: export.height)).",
                at: 3
            )
            parts.insert(
                "actualScale=\(export.actualScale.map { String(format: "%.2f", $0) } ?? "unknown").",
                at: 4
            )
            parts.insert(
                "scaleClamped=\(export.scaleClamped.map { String($0) } ?? "unknown").",
                at: 5
            )
        }

        return parts.joined(separator: " ")
    }

    private static func colorScheme(from theme: CanvasPreferencesState.Theme?) -> ColorScheme {
        switch theme {
            case .dark:
                return .dark
            case .light, nil:
                return .light
        }
    }

    private static func themeDescription(_ theme: CanvasPreferencesState.Theme?) -> String {
        switch theme {
            case .some(.dark):
                return "dark"
            case .some(.light):
                return "light"
            case nil:
                return "unknown"
        }
    }

    private static func sizeDescription(width: Double?, height: Double?) -> String {
        guard let width, let height else {
            return "unknown"
        }
        return "\(MCPJSONValue.integerText(width.rounded(.towardZero)))x\(MCPJSONValue.integerText(height.rounded(.towardZero)))"
    }
}

private enum CanvasImageToolImageBounds {
    /// Anthropic's documented "best efficiency" longest edge - anything bigger
    /// gets server-side resized anyway, but we still pay the upload cost. Cap
    /// locally so the wire payload stays compact and predictable.
    private static let maxImageEdge: CGFloat = 1568

    /// Downsample the PNG to fit within `maxImageEdge` on the longest side.
    /// If the original is already small enough, return it unchanged.
    /// On any decode/encode failure, fall back to the original — better to ship
    /// a too-large image than to fail the tool call.
    static func boundedPNG(_ data: Data) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return data
        }
        // Skip work if already within bounds.
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? CGFloat,
           let height = props[kCGImagePropertyPixelHeight] as? CGFloat,
           max(width, height) <= maxImageEdge {
            return data
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImageEdge
        ]
        guard let downsampled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return data
        }
        let buffer = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            buffer,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return data
        }
        CGImageDestinationAddImage(dest, downsampled, nil)
        guard CGImageDestinationFinalize(dest) else {
            return data
        }
        return buffer as Data
    }
}
