import XCTest
import CoreData
@testable import ExcalidrawZ

/// Moving a linked folder must carry the editor IDs of nested drawings along.
@MainActor
final class MoveLocalFolderTests: XCTestCase {
    func testNestedDrawingKeepsItsIDAfterFolderMove() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("move-" + UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let nested = source.appendingPathComponent("Nested", isDirectory: true)
        let target = root.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let drawing = nested.appendingPathComponent("Plan.excalidraw")
        try XCTUnwrap(ExcalidrawFile().content).write(to: drawing)

        let context = PersistenceController.shared.container.viewContext
        let sourceFolder = try LocalFolder(url: source, context: context)
        let targetFolder = try LocalFolder(url: target, context: context)
        try context.save()
        defer {
            context.delete(sourceFolder); context.delete(targetFolder)
            try? context.save()
        }

        let id = ExcalidrawFile.localFileID(for: drawing)
        try await LocalFileUtils.moveLocalFolder(sourceFolder.objectID, to: targetFolder.objectID, context: context)

        let moved = target.appendingPathComponent("Source/Nested/Plan.excalidraw")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        let mapping = ExcalidrawFile.localFileURLIDMapping
        let movedID = mapping.first { $0.key.resolvingSymlinksInPath().path == moved.resolvingSymlinksInPath().path }?.value
        XCTAssertEqual(movedID, id, "the open drawing's ID follows it into the moved folder")
    }
}
