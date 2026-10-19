import Foundation
import XCTest
@testable import ExcalidrawZ

final class EditorServerContainmentTests: XCTestCase {
    func testAssetPathsInsideEditorDirectoryAreServed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        for path in ["/index.html", "/assets/index-abc.js", "/assets/My%20Font.woff2", "/"] {
            XCTAssertTrue(ContainedDirectoryHTTPHandler.isContained(requestPath: path, in: root), path)
        }
    }

    func testTraversalOutsideEditorDirectoryIsRejected() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        for path in [
            "/../Info.plist", "/%2e%2e/%2e%2e/Info.plist", "/%2E%2E/etc/hosts",
            "/assets/../../secret", "/..%2fsecret", "/./index.html", "/index.html%00.js",
        ] {
            XCTAssertFalse(ContainedDirectoryHTTPHandler.isContained(requestPath: path, in: root), path)
        }
    }

    func testSymlinkEscapingEditorDirectoryIsRejected() throws {
        let root = try makeRoot()
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside.txt")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Data("secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.txt"), withDestinationURL: outside
        )
        XCTAssertFalse(ContainedDirectoryHTTPHandler.isContained(requestPath: "/link.txt", in: root))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("excalidraw-latest", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("assets"), withIntermediateDirectories: true
        )
        return root
    }
}
