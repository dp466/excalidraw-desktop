#if os(macOS)
import XCTest
import CoreData
@testable import ExcalidrawZ

@MainActor
final class AutosavePersistenceTests: XCTestCase {
    func testOperationalMetadataSurvivesCanvasPersistenceAndReopen() throws {
        let existing = try XCTUnwrap(ExcalidrawFile().content)
        let metadata: [String: Any] = ["network_device": [
            "interfaces": [["name": "internal1.40", "vlan": ["tagged": [40, 50, 60]]]],
            "extension": [true, NSNull(), 12.5, ["future": [1, "two"]]]
        ]]
        let element: [String: Any] = [
            "id": "operational-device", "type": "rectangle", "x": 10, "y": 20,
            "width": 100, "height": 50, "angle": 0, "strokeColor": "#1b1b1f",
            "backgroundColor": "transparent", "fillStyle": "solid", "strokeWidth": 1,
            "strokeStyle": "solid", "roughness": 1, "opacity": 100, "groupIds": [],
            "frameId": NSNull(), "roundness": NSNull(), "seed": 1, "version": 1,
            "versionNonce": 2, "isDeleted": false, "boundElements": NSNull(),
            "updated": 1, "link": NSNull(), "locked": false, "customData": metadata
        ]
        let payload = try JSONSerialization.data(withJSONObject: [
            "elements": [element], "files": [String: Any](), "appState": [String: Any]()
        ])
        let prepared = try ExcalidrawFile.prepareCanvasDataUpdate(
            existingContent: existing,
            data: .init(documentData: payload, elements: nil, files: [:])
        )
        let reopened = try ExcalidrawFile(data: prepared.content)
        XCTAssertEqual(reopened.elements.count, 1)
        let encoded = try JSONEncoder().encode(XCTUnwrap(reopened.elements.first))
        let actual = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: encoded) as? [String: Any])?["customData"]
        )
        XCTAssertEqual(
            actual as? NSDictionary,
            metadata as NSDictionary
        )
    }

    func testCanvasUpdateReplacesDamagedStoredContentInsteadOfCrashing() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "elements": [[String: Any]](), "files": [String: Any](), "appState": [String: Any]()
        ])
        for damaged in [Data("[]".utf8), Data("null".utf8), Data("not json".utf8)] {
            let prepared = try ExcalidrawFile.prepareCanvasDataUpdate(
                existingContent: damaged,
                data: .init(documentData: payload, elements: nil, files: [:])
            )
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: prepared.content) as? [String: Any]
            )
            XCTAssertEqual(object["type"] as? String, "excalidraw")
            XCTAssertNotNil(object["elements"] as? [Any])
            XCTAssertNoThrow(try ExcalidrawFile(data: prepared.content))
        }
    }

    func testHostedTestsUseOnlyInMemoryStores() {
        XCTAssertTrue(AppRuntime.isRunningTests)
        let stores = PersistenceController.shared.container.persistentStoreCoordinator.persistentStores
        XCTAssertEqual(stores.count, 2)
        XCTAssertTrue(stores.allSatisfy { $0.type == NSInMemoryStoreType })
    }

    func testAutosaveWaitsForDiskAndKeepsRecoveryWhenOriginalWriteFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("drawing.excalidraw")
        var scene = ExcalidrawFile()
        try XCTUnwrap(scene.content).write(to: destination)
        let state = FileState()
        state.mcpCheckpointSuppressionDepth = 1
        let recovery = root.appendingPathComponent("recovery")
        state.autosaveRecoveryStore = LocalAutosaveRecoveryStore(directory: recovery)
        let active = FileState.ActiveFile.temporaryFile(destination)
        let opened = await state.requestActiveFileChange(active)
        XCTAssertTrue(opened)
        state.shouldIgnoreUpdate = false // Emulate completed canvas loading.
        scene.id = active.id
        try await state.persistAutosave(scene)
        let disk = try Data(contentsOf: destination)
        _ = try ExcalidrawFile(data: disk)
        if case .saved = state.autosaveStatus {} else { XCTFail("Must acknowledge completed disk save") }

        // A directory occupying the destination guarantees atomic file replacement fails.
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            try await state.persistAutosave(scene)
            XCTFail("Storage failure must propagate")
        } catch {}
        if case .failed = state.autosaveStatus {} else { XCTFail("Failure must stay visible") }
        let enumerator = FileManager.default.enumerator(at: recovery, includingPropertiesForKeys: nil)!
        let copies = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "excalidraw" }
        XCTAssertFalse(copies.isEmpty)
        _ = try ExcalidrawFile(data: Data(contentsOf: XCTUnwrap(copies.first)))

        try FileManager.default.removeItem(at: destination)
        try await state.persistAutosave(scene)
        _ = try ExcalidrawFile(data: Data(contentsOf: destination))
        if case .saved = state.autosaveStatus {} else { XCTFail("A successful retry must clear the failure") }
    }

    func testStaleDocumentCannotOverwriteNewSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.excalidraw")
        let b = root.appendingPathComponent("b.excalidraw")
        var scene = ExcalidrawFile()
        let initial = try XCTUnwrap(scene.content)
        try initial.write(to: a)
        try initial.write(to: b)
        let state = FileState()
        state.autosaveRecoveryStore = LocalAutosaveRecoveryStore(directory: root.appendingPathComponent("recovery"))
        scene.id = FileState.ActiveFile.temporaryFile(a).id
        let opened = await state.requestActiveFileChange(.temporaryFile(b))
        XCTAssertTrue(opened)
        do { try await state.persistAutosave(scene); XCTFail("Stale document must be rejected") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: b), initial)
    }
    func testRecoveryFailureDoesNotRejectSuccessfulPrimarySave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("drawing.excalidraw")
        let blockedRecovery = root.appendingPathComponent("recovery")
        try Data("not a directory".utf8).write(to: blockedRecovery)
        var scene = ExcalidrawFile()
        try XCTUnwrap(scene.content).write(to: destination)
        let state = FileState()
        state.mcpCheckpointSuppressionDepth = 1
        state.autosaveRecoveryStore = LocalAutosaveRecoveryStore(directory: blockedRecovery)
        let active = FileState.ActiveFile.temporaryFile(destination)
        let opened = await state.requestActiveFileChange(active)
        XCTAssertTrue(opened)
        state.shouldIgnoreUpdate = false // Emulate completed canvas loading.
        scene.id = active.id
        // Success lets the snapshot coordinator acknowledge and clear native dirty state.
        try await state.persistAutosave(scene)
        _ = try ExcalidrawFile(data: Data(contentsOf: destination))
        if case .savedWithRecoveryWarning = state.autosaveStatus {} else {
            XCTFail("Primary save must succeed with a distinct recovery warning")
        }
    }

}
#endif
