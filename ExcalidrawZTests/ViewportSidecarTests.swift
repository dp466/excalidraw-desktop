import XCTest
@testable import ExcalidrawZ

/// Library autosaves move the device-local viewport into a sidecar.
final class ViewportSidecarTests: XCTestCase {
    private func document(elementCount: Int, scrollX: Double) throws -> Data {
        let elements: [[String: Any]] = (0..<elementCount).map { index in
            [
                "id": "element-\(index)", "type": "rectangle", "x": Double(index), "y": Double(index % 97),
                "width": 120.5, "height": 80.25, "angle": 0, "strokeColor": "#1e1e1e",
                "backgroundColor": "transparent", "fillStyle": "solid", "strokeWidth": 2,
                "roughness": 1, "opacity": 100, "seed": index, "version": 3, "versionNonce": index * 7,
                "isDeleted": false, "groupIds": [], "boundElements": [], "locked": false,
                "updated": 1_700_000_000_000 + index, "link": NSNull(), "frameId": NSNull(),
                "index": "a\(index)", "roundness": ["type": 3]
            ]
        }
        let object: [String: Any] = [
            "type": "excalidraw", "version": 2, "source": "test", "elements": elements,
            "appState": ["scrollX": scrollX, "scrollY": -40.0, "zoom": ["value": 1.25],
                         "width": 1280, "height": 800, "viewBackgroundColor": "#ffffff", "gridSize": 20],
            "files": [:]
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testSeparatedDocumentKeepsContentAndDropsViewport() async throws {
        let fileID = "viewport-sidecar-test-\(UUID().uuidString)"
        let source = try document(elementCount: 50, scrollX: 321)
        let separated = try await ExcalidrawViewportStateStore.shared
            .contentDataBySeparatingViewport(from: source, fileID: fileID)

        let sourceObject = try XCTUnwrap(JSONSerialization.jsonObject(with: source) as? [String: Any])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: separated) as? [String: Any])
        let appState = try XCTUnwrap(object["appState"] as? [String: Any])
        XCTAssertNil(appState["scrollX"]); XCTAssertNil(appState["zoom"]); XCTAssertNil(appState["width"])
        XCTAssertEqual(appState["gridSize"] as? Int, 20)
        XCTAssertEqual((object["elements"] as? [Any])?.count, 50)
        XCTAssertEqual(object["source"] as? String, sourceObject["source"] as? String)

        // The sidecar restores the viewport on the next open.
        let restored = try await ExcalidrawViewportStateStore.shared
            .contentDataByApplyingStoredViewport(to: separated, fileID: fileID)
        let restoredState = try XCTUnwrap(
            (JSONSerialization.jsonObject(with: restored) as? [String: Any])?["appState"] as? [String: Any]
        )
        XCTAssertEqual(restoredState["scrollX"] as? Double, 321)
        XCTAssertEqual((restoredState["zoom"] as? [String: Any])?["value"] as? Double, 1.25)

        // A later viewport change still reaches the sidecar.
        _ = try await ExcalidrawViewportStateStore.shared
            .contentDataBySeparatingViewport(from: try document(elementCount: 50, scrollX: 999), fileID: fileID)
        let moved = try await ExcalidrawViewportStateStore.shared
            .contentDataByApplyingStoredViewport(to: separated, fileID: fileID)
        let movedState = try XCTUnwrap(
            (JSONSerialization.jsonObject(with: moved) as? [String: Any])?["appState"] as? [String: Any]
        )
        XCTAssertEqual(movedState["scrollX"] as? Double, 999)
    }

    func testSeparateViewportCost() async throws {
        let fileID = "viewport-sidecar-bench-\(UUID().uuidString)"
        let source = try document(elementCount: 14_000, scrollX: 10)
        let clock = ContinuousClock()
        var samples: [Double] = []
        for _ in 0..<8 {
            let start = clock.now
            _ = try await ExcalidrawViewportStateStore.shared
                .contentDataBySeparatingViewport(from: source, fileID: fileID)
            let elapsed = clock.now - start
            samples.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        print(String(format: "BENCHVIEWPORT %.1f MB separate ms: ", Double(source.count) / 1_000_000)
              + samples.map { String(format: "%.1f", $0) }.joined(separator: " "))

        samples.removeAll()
        for _ in 0..<8 {
            let start = clock.now
            _ = try await ExcalidrawViewportStateStore.shared
                .contentDataByApplyingStoredViewport(to: source, fileID: fileID)
            let elapsed = clock.now - start
            samples.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        print(String(format: "BENCHVIEWPORT %.1f MB apply ms: ", Double(source.count) / 1_000_000)
              + samples.map { String(format: "%.1f", $0) }.joined(separator: " "))
    }

    func testNativeFileNameIsSetWithoutTouchingElements() throws {
        let source = try document(elementCount: 20, scrollX: 5)
        let named = try ExcalidrawDocumentAppStatePersistence.documentData(source, settingNativeFileName: "Plan \"A\"/é")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: named) as? [String: Any])
        XCTAssertEqual((object["appState"] as? [String: Any])?["name"] as? String, "Plan \"A\"/é")
        XCTAssertEqual((object["appState"] as? [String: Any])?["gridSize"] as? Int, 20)
        XCTAssertEqual((object["elements"] as? [Any])?.count, 20)
        // Already named: the bytes are returned as they are.
        XCTAssertEqual(try ExcalidrawDocumentAppStatePersistence.documentData(named, settingNativeFileName: "Plan \"A\"/é"), named)
        // A document without appState gains one.
        let bare = Data(#"{"type":"excalidraw","elements":[]}"#.utf8)
        let bareNamed = try ExcalidrawDocumentAppStatePersistence.documentData(bare, settingNativeFileName: "N")
        let bareObject = try XCTUnwrap(JSONSerialization.jsonObject(with: bareNamed) as? [String: Any])
        XCTAssertEqual((bareObject["appState"] as? [String: Any])?["name"] as? String, "N")
    }

    func testNativeFileNameCost() throws {
        let source = try document(elementCount: 14_000, scrollX: 10)
        let clock = ContinuousClock()
        var samples: [Double] = []
        for round in 0..<8 {
            let start = clock.now
            _ = try ExcalidrawDocumentAppStatePersistence.documentData(source, settingNativeFileName: "Drawing \(round)")
            let elapsed = clock.now - start
            samples.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        print(String(format: "BENCHVIEWPORT %.1f MB name ms: ", Double(source.count) / 1_000_000)
              + samples.map { String(format: "%.1f", $0) }.joined(separator: " "))
    }

    func testAppStateChangeCheckCost() throws {
        let source = try document(elementCount: 14_000, scrollX: 10)
        let appState = try JSONDecoder().decode(
            ExcalidrawCore.JSONValue.self,
            from: Data(##"{"viewBackgroundColor":"#000000","gridSize":20}"##.utf8)
        )
        XCTAssertTrue(try ExcalidrawDocumentAppStateSnapshotSaver.isAppStateSemanticallyChanged(appState, in: source))
        let clock = ContinuousClock()
        var samples: [Double] = []
        for _ in 0..<8 {
            let start = clock.now
            _ = try ExcalidrawDocumentAppStateSnapshotSaver.isAppStateSemanticallyChanged(appState, in: source)
            let elapsed = clock.now - start
            samples.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        print(String(format: "BENCHVIEWPORT %.1f MB appState check ms: ", Double(source.count) / 1_000_000)
              + samples.map { String(format: "%.1f", $0) }.joined(separator: " "))
    }
}
