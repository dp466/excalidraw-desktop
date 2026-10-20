import XCTest
import CoreData
@testable import ExcalidrawZ

/// Dragging a library drawing to a linked folder may delete the library copy
/// afterwards, so the export must either write the file or throw.
@MainActor
final class ExportToDiskTests: XCTestCase {
    func testNameWithSlashIsWrittenAndFailuresThrow() async throws {
        let stores = PersistenceController.shared.container.persistentStoreCoordinator.persistentStores
        XCTAssertTrue(AppRuntime.isRunningTests && stores.allSatisfy { $0.type == NSInMemoryStoreType })
        let context = PersistenceController.shared.container.viewContext
        let group = Group(name: "Export \(UUID().uuidString.prefix(6))", context: context)
        try context.save()
        let content = try XCTUnwrap(ExcalidrawFile().content)
        let fileID = try await PersistenceController.shared.fileRepository.createFile(
            name: "Q3/Q4: plan", content: content, groupObjectID: group.objectID
        )

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await PersistenceController.shared.fileRepository.exportToDisk(fileObjectID: fileID, folder: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Q3-Q4- plan.excalidraw").path))

        // A destination that cannot be written reports an error.
        let missing = folder.appendingPathComponent("missing", isDirectory: true)
        do {
            try await PersistenceController.shared.fileRepository.exportToDisk(fileObjectID: fileID, folder: missing)
            XCTFail("Writing into a missing folder must throw")
        } catch {}
    }
}
