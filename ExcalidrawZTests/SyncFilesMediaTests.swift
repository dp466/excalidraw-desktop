import XCTest
import CoreData
@testable import ExcalidrawZ

/// Export, archive and backup gather a library drawing's images with
/// `syncFiles(context:)`; they must find them in an on-disk store.
final class SyncFilesMediaTests: XCTestCase {
    func testSyncFilesFindsTheDrawingsImagesInSQLiteStore() async throws {
        let modelURL = try XCTUnwrap(Bundle.main.url(forResource: "Model", withExtension: "momd"))
        let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("syncfiles-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = NSPersistentContainer(name: "Model", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: directory.appendingPathComponent("store.sqlite"))
        description.type = NSSQLiteStoreType
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        defer {
            for store in container.persistentStoreCoordinator.persistentStores {
                try? container.persistentStoreCoordinator.remove(store)
            }
        }

        let context = container.newBackgroundContext()
        let fileID = UUID()
        try await context.perform {
            let file = File(context: context)
            file.id = fileID; file.name = "with image"; file.createdAt = .now; file.updatedAt = .now
            let other = File(context: context)
            other.id = UUID(); other.name = "other"; other.createdAt = .now; other.updatedAt = .now
            for (owner, mediaID) in [(file, "img-own"), (other, "img-other")] {
                let item = MediaItem(context: context)
                item.id = mediaID
                item.mimeType = "image/png"
                item.dataURL = "data:image/png;base64,AAAA"
                item.file = owner
            }
            try context.save()
        }

        var drawing = ExcalidrawFile()
        drawing.id = fileID.uuidString
        try await drawing.syncFiles(context: context)
        XCTAssertEqual(Set(drawing.files.keys), ["img-own"])
        let content = try XCTUnwrap(drawing.content)
        let files = try XCTUnwrap((try JSONSerialization.jsonObject(with: content) as? [String: Any])?["files"] as? [String: Any])
        XCTAssertEqual(Set(files.keys), ["img-own"], "the scene written out carries the image")
    }

    func testResourceFileAcceptsFractionalTimestamps() throws {
        let json = #"{"mimeType":"image/png","id":"a","dataURL":"data:image/png;base64,AAAA","created":1700000000123.5,"lastRetrieved":1700000000456}"#
        let file = try JSONDecoder().decode(ExcalidrawFile.ResourceFile.self, from: Data(json.utf8))
        XCTAssertEqual(try XCTUnwrap(file.createdAt).timeIntervalSince1970, 1700000000.1235, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(file.lastRetrievedAt).timeIntervalSince1970, 1700000000.456, accuracy: 0.0001)
    }
}
