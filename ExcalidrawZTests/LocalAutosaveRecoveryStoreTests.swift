import Foundation
import XCTest
@testable import ExcalidrawZ

final class LocalAutosaveRecoveryStoreTests: XCTestCase {
    func testFirstSaveCreatesCurrentCopyInHashedDocumentDirectory() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAutosaveRecoveryStore(directory: root)
        let data = try drawingData(elementID: "first")

        try await store.save(documentID: "document-1", name: "My Drawing", content: data)

        let recoveryDirectory = try await store.recoveryDirectory()
        XCTAssertEqual(recoveryDirectory, root.standardizedFileURL.resolvingSymlinksInPath())
        let documentDirectories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        XCTAssertEqual(documentDirectories.count, 1)
        XCTAssertEqual(documentDirectories[0].lastPathComponent.count, 64)

        let copies = try recoveryCopies(in: documentDirectories[0])
        XCTAssertEqual(copies.map(\.lastPathComponent), ["current-My_Drawing-v2.excalidraw"])
        XCTAssertEqual(try Data(contentsOf: copies[0]), data)
    }

    func testReplacementRetainsPreviousCopyAndSkipsIdenticalBytes() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAutosaveRecoveryStore(directory: root)
        let first = try drawingData(elementID: "first")
        let replacement = try drawingData(elementID: "replacement")

        try await store.save(documentID: "document-1", name: "Board", content: first)
        try await store.save(documentID: "document-1", name: "Board", content: replacement)

        let documentDirectory = try onlyDocumentDirectory(in: root)
        var copies = try recoveryCopies(in: documentDirectory)
        XCTAssertEqual(copies.map(\.lastPathComponent), [
            "current-Board-v2.excalidraw",
            "previous-Board-v2.excalidraw",
        ])
        let current = try XCTUnwrap(copies.first { $0.lastPathComponent.hasPrefix("current-") })
        let previous = try XCTUnwrap(copies.first { $0.lastPathComponent.hasPrefix("previous-") })
        XCTAssertEqual(try Data(contentsOf: current), replacement)
        XCTAssertEqual(try Data(contentsOf: previous), first)

        try await store.save(documentID: "document-1", name: "Renamed Board", content: replacement)
        copies = try recoveryCopies(in: documentDirectory)
        XCTAssertEqual(copies.map(\.lastPathComponent), [
            "current-Board-v2.excalidraw",
            "previous-Board-v2.excalidraw",
        ])
    }

    func testUnchangedSaveSkipsRewriteButRestoresMissingCopyAndTracksLatestBytes() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAutosaveRecoveryStore(directory: root)
        let first = try drawingData(elementID: "first")
        let second = try drawingData(elementID: "second")

        try await store.save(documentID: "document-1", name: "Board", content: first)
        let documentDirectory = try onlyDocumentDirectory(in: root)
        let current = try XCTUnwrap(try recoveryCopies(in: documentDirectory).first)
        let installedAt = try XCTUnwrap(
            try current.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )

        try await store.save(documentID: "document-1", name: "Board", content: first)
        XCTAssertEqual(
            try current.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
            installedAt
        )

        // A copy removed outside the store is written again, not assumed present.
        try FileManager.default.removeItem(at: current)
        try await store.save(documentID: "document-1", name: "Board", content: first)
        XCTAssertEqual(try Data(contentsOf: current), first)

        // A -> B -> A must install A again; the cached fingerprint follows the latest copy.
        try await store.save(documentID: "document-1", name: "Board", content: second)
        try await store.save(documentID: "document-1", name: "Board", content: first)
        let copies = try recoveryCopies(in: documentDirectory)
        let latest = try XCTUnwrap(copies.first { $0.lastPathComponent.hasPrefix("current-") })
        let previous = try XCTUnwrap(copies.first { $0.lastPathComponent.hasPrefix("previous-") })
        XCTAssertEqual(try Data(contentsOf: latest), first)
        XCTAssertEqual(try Data(contentsOf: previous), second)
    }

    func testInvalidPayloadDoesNotReplaceExistingRecoveryCopy() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAutosaveRecoveryStore(directory: root)
        let valid = try drawingData(elementID: "safe")
        try await store.save(documentID: "document-1", name: "Board", content: valid)

        do {
            try await store.save(
                documentID: "document-1",
                name: "Board",
                content: Data(#"{"type":"excalidraw","version":2}"#.utf8)
            )
            XCTFail("An incomplete Excalidraw payload should not be saved")
        } catch LocalAutosaveRecoveryStore.RecoveryError.invalidExcalidrawPayload {
            // Expected.
        }

        let copies = try recoveryCopies(in: try onlyDocumentDirectory(in: root))
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try Data(contentsOf: copies[0]), valid)
    }

    func testImageDocumentJSONCanBeReopenedFromRecoveryCopy() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAutosaveRecoveryStore(directory: root)
        let imageDrawing = try JSONSerialization.data(withJSONObject: [
            "type": "excalidraw",
            "version": 2,
            "elements": [["id": "image-1", "type": "image", "fileId": "image-file"]],
            "appState": ["viewBackgroundColor": "#ffffff"],
            "files": ["image-file": ["id": "image-file", "dataURL": "data:image/png;base64,AA=="]],
        ], options: [.sortedKeys])

        try await store.save(documentID: "image-document", name: "Image Board", content: imageDrawing)

        let copy = try XCTUnwrap(recoveryCopies(in: try onlyDocumentDirectory(in: root)).first)
        let reopened = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: copy)) as? [String: Any])
        XCTAssertEqual(reopened["type"] as? String, "excalidraw")
        XCTAssertEqual((reopened["elements"] as? [[String: Any]])?.first?["fileId"] as? String, "image-file")
        XCTAssertNotNil((reopened["files"] as? [String: Any])?["image-file"])
    }

    func testRetentionPrunesOldDocumentDirectoriesButKeepsActiveDocument() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAutosaveRecoveryStore(
            directory: root,
            retention: .init(maximumDocuments: 2, maximumBytes: .max)
        )

        try await store.save(documentID: "document-1", name: "One", content: try drawingData(elementID: "one"))
        try await store.save(documentID: "document-2", name: "Two", content: try drawingData(elementID: "two"))
        let activeData = try drawingData(elementID: "three")
        try await store.save(documentID: "document-3", name: "Three", content: activeData)

        let documentDirectories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        XCTAssertEqual(documentDirectories.count, 2)
        let storedCopies = try documentDirectories.flatMap { try recoveryCopies(in: $0) }
        let storedData = try storedCopies.map { try Data(contentsOf: $0) }
        XCTAssertTrue(storedData.contains(activeData))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func onlyDocumentDirectory(in root: URL) throws -> URL {
        try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).first)
    }

    private func recoveryCopies(in documentDirectory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: documentDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "excalidraw" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func drawingData(elementID: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "excalidraw",
            "version": 2,
            "elements": [["id": elementID, "type": "rectangle"]],
            "appState": [:],
            "files": [:],
        ], options: [.sortedKeys])
    }
}
