//
//  AddLibraryItemToCanvasTool.swift
//  ExcalidrawZ
//
//  Inserts a library item's elements onto the current canvas at a
//  user-specified position. Bridges the gap between
//  `query_library_item` (read-only inspection) and `adjust_elements`
//  (per-element add ops) — for "stamp this saved shape onto the
//  canvas at (x, y)" the AI no longer needs to write per-element add
//  ops by hand, which got verbose for items with many parts (arrows
//  + bound text + groups).
//
//  Two non-trivial bits of plumbing this tool handles internally:
//
//  1. **Translation**: library items are stored in their original
//     authoring coordinates. Caller specifies the target top-left of
//     the bounding box; we compute the offset and shift every
//     element's x/y. (Inner `points` for lines/arrows/freeDraw are
//     relative to each element's x/y, so they don't need adjusting.)
//
//  2. **ID regeneration**: library item ids are stable, so naively
//     calling `addElements` twice would create two elements sharing
//     ids — undefined behaviour in Excalidraw. We mint fresh nanoIDs
//     for every element id AND for every group id, then walk the
//     JSON to remap all internal references (`containerId`,
//     `boundElements[*].id`, `startBinding.elementId`,
//     `endBinding.elementId`, `frameId`, `groupIds[*]`). External
//     references (pointing to canvas elements not in this item) are
//     left as-is — they were already broken in the library blob; we
//     don't try to "fix" them.
//

import Foundation
import CoreData
import LLMCore

struct AddLibraryItemToCanvasTool: Tool {
    struct AddContext: ToolContext {
        var canvasTarget: ExcalidrawCoordinatorRegistry.CanvasTarget
        var currentFileID: UUID? = nil
    }

    var name: String { "add_library_item_to_canvas" }

    var displayName: String { String(localizable: .aiChatToolInsertLibraryItemName) }

    var description: String {
        """
        Insert a library item's shapes onto the current canvas at a \
        specified position. Get (library_id, item_id) from \
        `list_library_items` / `query_library_item`. The item's \
        bounding box top-left lands at (x, y); use this to place \
        copies of saved reusable shapes without writing per-element \
        add ops in `adjust_elements`. Each call mints fresh ids, so \
        you can stamp the same item multiple times without collision.
        """
    }

    var inputSchema: ToolInputSchema {
        .parameters(ToolParameters(
            properties: [
                "library_id": ParameterProperty(
                    type: "string",
                    description: "UUID of the library."
                ),
                "item_id": ParameterProperty(
                    type: "string",
                    description: "Item id (string) within the library."
                ),
                "x": ParameterProperty(
                    type: "number",
                    description: "Target canvas x for the bounding-box top-left, in canvas coordinates. Defaults to 0."
                ),
                "y": ParameterProperty(
                    type: "number",
                    description: "Target canvas y for the bounding-box top-left. Defaults to 0."
                )
            ],
            required: ["library_id", "item_id"]
        ))
    }

    func execute(_ input: String, context: (any ChatInvocationContext)?) async throws -> ToolResult {
        try AIChatToolExecutionGate.ensureAIEnabled()

        let params = try parseInput(input)
        guard let context else {
            throw ToolError.executionFailed("Missing canvas context — tool needs an active Excalidraw coordinator.")
        }
        let addContext = try context.resolve(AddContext.self)
        guard try await LockedContentAIGuard.canToolAccess(fileID: addContext.currentFileID) else {
            return LockedContentAIGuard.lockedToolResult
        }

        // 1. Load the item's elements blob.
        let elementsBlob = try await loadElementsBlob(
            libraryID: params.libraryID,
            itemID: params.itemID
        )

        // 2. Transform (translate + remap ids), then decode as
        //    [ExcalidrawElement] for the coordinator API.
        let decodedElements = try LibraryItemCanvasElementPreprocessor.prepare(
            blob: elementsBlob,
            placement: .topLeft(x: params.x, y: params.y)
        )

        // 3. Push to canvas.
        try await applyToCanvas(
            elements: decodedElements,
            canvasTarget: addContext.canvasTarget
        )

        // 4. Surface the new ids so the AI can chain follow-ups
        //    (`adjust_elements` updates / arrow bindings against the
        //    just-inserted shapes).
        let newIDs = decodedElements.map { $0.id }
        let response: [String: Any] = [
            "ok": true,
            "added_count": newIDs.count,
            "new_element_ids": newIDs
        ]
        let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        return .text(String(data: data, encoding: .utf8) ?? "{}")
    }

    // MARK: - Core Data lookup

    private func loadElementsBlob(libraryID: String, itemID: String) async throws -> Data {
        let ctx = PersistenceController.shared.newTaskContext()
        return try await ctx.perform {
            let libFetch = NSFetchRequest<Library>(entityName: "Library")
            libFetch.predicate = NSPredicate(format: "id == %@", (UUID(uuidString: libraryID) as CVarArg?) ?? libraryID as CVarArg)
            libFetch.fetchLimit = 1
            guard let library = try ctx.fetch(libFetch).first else {
                throw ToolError.executionFailed("Library not found: \(libraryID)")
            }
            let itemFetch = NSFetchRequest<LibraryItem>(entityName: "LibraryItem")
            itemFetch.predicate = NSPredicate(
                format: "library == %@ AND id == %@",
                library, itemID
            )
            itemFetch.fetchLimit = 1
            guard let item = try ctx.fetch(itemFetch).first else {
                throw ToolError.executionFailed("Item '\(itemID)' not found in library.")
            }
            guard let blob = item.elements, !blob.isEmpty else {
                throw ToolError.executionFailed("Item '\(itemID)' has no elements.")
            }
            return blob
        }
    }

    // MARK: - Canvas

    @MainActor
    private func applyToCanvas(
        elements: [ExcalidrawElement],
        canvasTarget: ExcalidrawCoordinatorRegistry.CanvasTarget
    ) async throws {
        guard let coordinator = ExcalidrawCoordinatorRegistry.shared.coordinator(for: canvasTarget) else {
            throw ToolError.executionFailed("Missing active Excalidraw coordinator")
        }
        try await coordinator.addElements(elements)
    }

    // MARK: - Input

    private struct Params {
        var libraryID: String
        var itemID: String
        var x: Double?
        var y: Double?
    }

    private func parseInput(_ input: String) throws -> Params {
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError.invalidInput("Expected JSON object with `library_id` and `item_id`.")
        }
        guard let libraryID = json["library_id"] as? String, !libraryID.isEmpty else {
            throw ToolError.invalidInput("Missing required parameter: library_id")
        }
        guard let itemID = json["item_id"] as? String, !itemID.isEmpty else {
            throw ToolError.invalidInput("Missing required parameter: item_id")
        }
        return Params(
            libraryID: libraryID,
            itemID: itemID,
            x: numeric(json["x"]),
            y: numeric(json["y"])
        )
    }

    /// JSONSerialization may decode numerics as `Int`, `Double`, or
    /// `NSNumber` depending on the literal — coerce to `Double?`.
    private func numeric(_ any: Any?) -> Double? {
        if let n = any as? Double { return n }
        if let n = any as? Int { return Double(n) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }
}

enum LibraryItemCanvasElementPreprocessor {
    enum Placement {
        case original
        case topLeft(x: Double?, y: Double?)
        case center(x: Double, y: Double)
    }

    enum PreparationError: LocalizedError {
        case emptyElements
        case invalidElementsJSON

        var errorDescription: String? {
            switch self {
                case .emptyElements:
                    return "Library item has no elements."
                case .invalidElementsJSON:
                    return "Library item elements data is not a JSON array."
            }
        }
    }

    static func prepare(
        elements: [ExcalidrawElement],
        placement: Placement
    ) throws -> [ExcalidrawElement] {
        guard !elements.isEmpty else {
            throw PreparationError.emptyElements
        }
        let data = try JSONEncoder().encode(elements)
        return try prepare(blob: data, placement: placement)
    }

    static func prepare(
        blob: Data,
        placement: Placement
    ) throws -> [ExcalidrawElement] {
        let transformedData = try transformElements(blob: blob, placement: placement)
        return try JSONDecoder().decode([ExcalidrawElement].self, from: transformedData)
    }

    /// Apply (translate + id-regen) to the raw elements JSON. We work
    /// at the JSON-dict level rather than going through `ExcalidrawElement`
    /// because the enum's value-type variants make in-place mutation
    /// awkward (you'd reconstruct each shape variant by hand).
    private static func transformElements(
        blob: Data,
        placement: Placement
    ) throws -> Data {
        guard var elements = try JSONSerialization.jsonObject(with: blob) as? [[String: Any]] else {
            throw PreparationError.invalidElementsJSON
        }
        guard !elements.isEmpty else {
            throw PreparationError.emptyElements
        }

        let offset = computeOffset(elements: elements, placement: placement)
        let idMapping = makeElementIDMapping(elements)
        let groupIDMapping = makeGroupIDMapping(elements)

        for index in elements.indices {
            elements[index] = remapIDs(
                in: elements[index],
                idMapping: idMapping,
                groupIDMapping: groupIDMapping
            )
            if let dx = offset?.dx, let x = number(elements[index]["x"]) {
                elements[index]["x"] = x + dx
            }
            if let dy = offset?.dy, let y = number(elements[index]["y"]) {
                elements[index]["y"] = y + dy
            }
        }

        return try JSONSerialization.data(withJSONObject: elements)
    }

    private static func computeOffset(
        elements: [[String: Any]],
        placement: Placement
    ) -> (dx: Double, dy: Double)? {
        switch placement {
            case .original:
                return nil
            case .topLeft(let x, let y):
                guard x != nil || y != nil else { return nil }
                guard let bounds = bounds(of: elements) else {
                    return (x ?? 0, y ?? 0)
                }
                return (
                    dx: (x ?? bounds.minX) - bounds.minX,
                    dy: (y ?? bounds.minY) - bounds.minY
                )
            case .center(let x, let y):
                guard let bounds = bounds(of: elements) else {
                    return (x, y)
                }
                return (
                    dx: x - bounds.midX,
                    dy: y - bounds.midY
                )
        }
    }

    private static func makeElementIDMapping(_ elements: [[String: Any]]) -> [String: String] {
        var mapping: [String: String] = [:]
        for element in elements {
            if let id = element["id"] as? String {
                mapping[id] = mapping[id] ?? ExcalidrawNanoID.make()
            }
        }
        return mapping
    }

    private static func makeGroupIDMapping(_ elements: [[String: Any]]) -> [String: String] {
        var mapping: [String: String] = [:]
        for element in elements {
            guard let groupIDs = element["groupIds"] as? [String] else { continue }
            for groupID in groupIDs {
                mapping[groupID] = mapping[groupID] ?? ExcalidrawNanoID.make()
            }
        }
        return mapping
    }

    /// Walk a single element's JSON dict and substitute ids using the
    /// supplied mappings. Foreign refs (ids not in our mapping) are left
    /// untouched.
    private static func remapIDs(
        in element: [String: Any],
        idMapping: [String: String],
        groupIDMapping: [String: String]
    ) -> [String: Any] {
        var output = element

        if let id = output["id"] as? String,
           let newID = idMapping[id] {
            output["id"] = newID
        }

        for key in ["containerId", "frameId"] {
            if let id = output[key] as? String,
               let newID = idMapping[id] {
                output[key] = newID
            }
        }

        if var boundElements = output["boundElements"] as? [[String: Any]] {
            for index in boundElements.indices {
                if let id = boundElements[index]["id"] as? String,
                   let newID = idMapping[id] {
                    boundElements[index]["id"] = newID
                }
            }
            output["boundElements"] = boundElements
        }

        for key in ["startBinding", "endBinding"] {
            if var binding = output[key] as? [String: Any],
               let id = binding["elementId"] as? String,
               let newID = idMapping[id] {
                binding["elementId"] = newID
                output[key] = binding
            }
        }

        if let groupIDs = output["groupIds"] as? [String] {
            output["groupIds"] = groupIDs.map { groupIDMapping[$0] ?? $0 }
        }

        return output
    }

    private struct Bounds {
        var minX: Double
        var minY: Double
        var maxX: Double
        var maxY: Double

        var midX: Double { (minX + maxX) / 2 }
        var midY: Double { (minY + maxY) / 2 }
    }

    private static func bounds(of elements: [[String: Any]]) -> Bounds? {
        var result: Bounds?
        for element in elements {
            guard let x = number(element["x"]),
                  let y = number(element["y"]) else {
                continue
            }
            let width = number(element["width"]) ?? 0
            let height = number(element["height"]) ?? 0
            let minX = min(x, x + width)
            let minY = min(y, y + height)
            let maxX = max(x, x + width)
            let maxY = max(y, y + height)

            if let current = result {
                result = Bounds(
                    minX: Swift.min(current.minX, minX),
                    minY: Swift.min(current.minY, minY),
                    maxX: Swift.max(current.maxX, maxX),
                    maxY: Swift.max(current.maxY, maxY)
                )
            } else {
                result = Bounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
            }
        }
        return result
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }
}
