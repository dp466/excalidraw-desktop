import XCTest
@testable import ExcalidrawZ

/// Any finite JSON number is valid input; converting one outside Int's range
/// with `Int(_:)` would crash the app.
final class MCPNumberBoundsTests: XCTestCase {
    func testHugeDeleteIDDoesNotCrash() async throws {
        let resolver = ExcalidrawMCPUpstreamElementResolver(loadCheckpointElements: { _ in nil })
        let result = try await resolver.resolve([
            .object(["type": .string("rectangle"), "id": .string("keep")]),
            .object(["type": .string("delete"), "ids": .number(1e20)]),
            .object(["type": .string("delete"), "ids": .array([.number(-1e300), .number(42)])])
        ])
        XCTAssertEqual(result.elements.count, 1)
    }

    func testIntegerTextAndClamp() {
        XCTAssertEqual(MCPJSONValue.integerText(42), "42")
        XCTAssertEqual(MCPJSONValue.integerText(1.5), "1.5")
        XCTAssertEqual(MCPJSONValue.integerText(1e20), "1e+20")
        XCTAssertEqual(MCPJSONValue.clampedInteger(1e20, default: 100, in: 1...200), 200)
        XCTAssertEqual(MCPJSONValue.clampedInteger(-1e20, default: 100, in: 1...200), 1)
        XCTAssertEqual(MCPJSONValue.clampedInteger(nil, default: 100, in: 1...200), 100)
        XCTAssertEqual(MCPJSONValue.clampedInteger(50.9, default: 100, in: 1...200), 50)
    }
}

final class MCPToolArtifactTests: XCTestCase {
    func testOnlyTemporaryFilesAreAttached() throws {
        let artifact = FileManager.default.temporaryDirectory.appendingPathComponent("artifact-\(UUID().uuidString).png")
        try Data([1]).write(to: artifact)
        defer { try? FileManager.default.removeItem(at: artifact) }
        XCTAssertTrue(ExcalidrawMCPLLMCoreToolAdapter.isToolArtifact(artifact))
        XCTAssertFalse(ExcalidrawMCPLLMCoreToolAdapter.isToolArtifact(URL(fileURLWithPath: "/etc/hosts")))
        XCTAssertFalse(ExcalidrawMCPLLMCoreToolAdapter.isToolArtifact(
            FileManager.default.temporaryDirectory.appendingPathComponent("../../../../etc/hosts")
        ))
    }
}

final class MCPCheckpointStoreBoundsTests: XCTestCase {
    func testOnlyTheNewestCheckpointsAreKept() async throws {
        let store = ExcalidrawMCPDiagramSessionStore()
        let limit = ExcalidrawMCPDiagramSessionStore.maximumCheckpointCount
        for index in 0..<(limit + 20) {
            try await store.saveCheckpoint(id: "c\(index)", data: .object(["elements": .array([])]))
        }
        let oldest = await store.checkpoint(id: "c0")
        let newest = await store.checkpoint(id: "c\(limit + 19)")
        let firstKept = await store.checkpoint(id: "c20")
        XCTAssertNil(oldest)
        XCTAssertNotNil(newest)
        XCTAssertNotNil(firstKept)
        // Re-saving an id refreshes it instead of duplicating it.
        try await store.saveCheckpoint(id: "c20", data: .object(["elements": .array([])]))
        try await store.saveCheckpoint(id: "extra", data: .object(["elements": .array([])]))
        let refreshed = await store.checkpoint(id: "c20")
        let evicted = await store.checkpoint(id: "c21")
        XCTAssertNotNil(refreshed)
        XCTAssertNil(evicted)
    }
}

final class MCPReceiptBoundsTests: XCTestCase {
    func testReceiptFileKeepsOnlyTheNewestReceipts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let receiptURL = directory.appendingPathComponent("receipts.json")
        let service = ExcalidrawMCPDiagramCommandService(receiptURL: receiptURL) { _, arguments, _ in
            .init(text: "ok", structuredContent: .object(["request": arguments["request_id"] ?? .null]))
        }
        let limit = ExcalidrawMCPDiagramCommandService.maximumReceiptCount
        for index in 0..<(limit + 40) {
            _ = try await service.callTool(
                name: "document_command",
                arguments: ["action": .string("create"), "name": .string("N"), "request_id": .string("r\(index)")],
                clientID: "client"
            )
        }
        let disk = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any])
        XCTAssertEqual(disk.count, limit)
        XCTAssertNotNil(disk["client\u{0}r\(limit + 39)"])
        XCTAssertNil(disk["client\u{0}r0"])
    }
}

final class AIToolNumberBoundsTests: XCTestCase {
    func testFontFamilyIDIsBounded() {
        XCTAssertEqual(AdjustElementsTool.fontFamilyID(nil), 5)
        XCTAssertEqual(AdjustElementsTool.fontFamilyID(1e20), 1_000)
        XCTAssertEqual(AdjustElementsTool.fontFamilyID(-3), 1)
        XCTAssertEqual(AdjustElementsTool.fontFamilyID(2), 2)
    }
}

final class TransferableFileNameTests: XCTestCase {
    func testNameWithSlashProducesARealFile() throws {
        var file = ExcalidrawFile()
        file.name = "Q3/Q4: plan"
        let url = try file.fileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.lastPathComponent, "Q3-Q4- plan.excalidraw")
    }
}
