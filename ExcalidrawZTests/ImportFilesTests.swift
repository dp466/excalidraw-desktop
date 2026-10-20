import XCTest
import CoreData
@testable import ExcalidrawZ

/// Importing several drawings at once with no group selected.
@MainActor
final class ImportFilesTests: XCTestCase {
    private func drawing(imageID: String?) -> [String: Any] {
        var files: [String: Any] = [:]
        if let imageID {
            files[imageID] = [
                "id": imageID, "mimeType": "image/png", "created": 1,
                "dataURL": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
            ]
        }
        return ["type": "excalidraw", "version": 2, "source": "test", "elements": [],
                "appState": ["viewBackgroundColor": "#ffffff"], "files": files]
    }

    func testMultipleFilesImportWithoutSelectedGroupStoresMediaSeparately() async throws {
        let stores = PersistenceController.shared.container.persistentStoreCoordinator.persistentStores
        XCTAssertTrue(AppRuntime.isRunningTests && stores.allSatisfy { $0.type == NSInMemoryStoreType })
        let context = PersistenceController.shared.container.viewContext
        if try PersistenceController.shared.getDefaultGroup(context: context) == nil {
            let group = Group(name: "Default", context: context)
            group.groupType = .default
            try context.save()
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tag = UUID().uuidString.prefix(8)
        let imageID = "import-image-\(tag)"
        let first = root.appendingPathComponent("first-\(tag).excalidraw")
        let second = root.appendingPathComponent("second-\(tag).excalidraw")
        try JSONSerialization.data(withJSONObject: drawing(imageID: imageID)).write(to: first)
        try JSONSerialization.data(withJSONObject: drawing(imageID: nil)).write(to: second)

        let state = FileState()
        try await state.importFiles([first, second])

        let request = NSFetchRequest<File>(entityName: "File")
        request.predicate = NSPredicate(format: "name == %@", "first-\(tag)")
        let imported = try XCTUnwrap(context.fetch(request).first)
        let content = try await imported.loadContent()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: content) as? [String: Any])
        XCTAssertNil(object["files"], "embedded images are stored as media items, not inline")
        let media = NSFetchRequest<MediaItem>(entityName: "MediaItem")
        media.predicate = NSPredicate(format: "id == %@", imageID)
        XCTAssertEqual(try context.count(for: media), 1)
        request.predicate = NSPredicate(format: "name == %@", "second-\(tag)")
        XCTAssertEqual(try context.count(for: request), 1)
    }
}
