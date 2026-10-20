import Foundation
import XCTest
@testable import ExcalidrawZ

final class AppStateSemanticChangeTests: XCTestCase {
    func testChangeCheckMatchesMergeDecision() throws {
        let content = try JSONSerialization.data(withJSONObject: [
            "type": "excalidraw", "version": 2, "elements": [[String: Any]](), "files": [String: Any](),
            "appState": ["viewBackgroundColor": "#ffffff", "currentItemStrokeColor": "#1e1e1e", "scrollX": 10],
        ])
        let cases: [(String, [String: Any], Data)] = [
            ("unchanged", ["viewBackgroundColor": "#ffffff", "currentItemStrokeColor": "#1e1e1e"], content),
            ("viewport only", ["viewBackgroundColor": "#ffffff", "currentItemStrokeColor": "#1e1e1e", "scrollX": 500], content),
            ("persistent field", ["viewBackgroundColor": "#000000", "currentItemStrokeColor": "#1e1e1e"], content),
            ("new tool default", ["viewBackgroundColor": "#ffffff", "currentItemStrokeColor": "#e03131"], content),
            ("non-object content", ["viewBackgroundColor": "#ffffff"], Data("[]".utf8)),
        ]
        for (name, appState, stored) in cases {
            let value = try JSONDecoder().decode(
                ExcalidrawCore.JSONValue.self, from: JSONSerialization.data(withJSONObject: appState)
            )
            let merged = try ExcalidrawDocumentAppStateSnapshotSaver.mergingAppStateIfSemanticallyChanged(
                value, into: stored, nativeFileName: nil
            )
            let changed = try ExcalidrawDocumentAppStateSnapshotSaver.isAppStateSemanticallyChanged(value, in: stored)
            XCTAssertEqual(changed, merged != nil, name)
        }
        let unchanged = try JSONDecoder().decode(ExcalidrawCore.JSONValue.self, from: JSONSerialization.data(
            withJSONObject: ["viewBackgroundColor": "#ffffff", "currentItemStrokeColor": "#1e1e1e"]))
        XCTAssertFalse(try ExcalidrawDocumentAppStateSnapshotSaver.isAppStateSemanticallyChanged(unchanged, in: content))
        let changed = try JSONDecoder().decode(ExcalidrawCore.JSONValue.self, from: JSONSerialization.data(
            withJSONObject: ["viewBackgroundColor": "#000000"]))
        XCTAssertTrue(try ExcalidrawDocumentAppStateSnapshotSaver.isAppStateSemanticallyChanged(changed, in: content))
    }
}
