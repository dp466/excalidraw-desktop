#if os(macOS)
import XCTest
import AppKit
import CoreData
import SwiftUI
@testable import ExcalidrawZ

/// Real bundled editor, disposable folder, in-memory database.
@MainActor
final class BoundarySaveTests: XCTestCase {
    func testViewingDoesNotRewriteButUnsignalledEditIsSaved() async throws {
        let stores = PersistenceController.shared.container.persistentStoreCoordinator.persistentStores
        XCTAssertTrue(AppRuntime.isRunningTests && stores.allSatisfy { $0.type == NSInMemoryStoreType })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("boundary-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = PersistenceController.shared.container.viewContext
        let folder = try LocalFolder(url: root, context: context)
        try context.save()
        let url = root.appendingPathComponent("drawing.excalidraw")
        let scene: [String: Any] = [
            "type": "excalidraw", "version": 2, "source": "https://excalidraw.com",
            "elements": [[
                "id": "seed", "type": "rectangle", "x": 10, "y": 20, "width": 120, "height": 60, "angle": 0,
                "strokeColor": "#1e1e1e", "backgroundColor": "transparent", "fillStyle": "solid", "strokeWidth": 2,
                "strokeStyle": "solid", "roughness": 1, "opacity": 100, "groupIds": [String](), "frameId": NSNull(),
                "roundness": NSNull(), "seed": 1, "version": 1, "versionNonce": 1, "isDeleted": false,
                "boundElements": NSNull(), "updated": 1, "link": NSNull(), "locked": false,
            ]],
            "appState": ["viewBackgroundColor": "#ffffff"], "files": [String: Any](),
        ]
        try JSONSerialization.data(withJSONObject: scene).write(to: url)

        let state = FileState()
        state.currentActiveGroup = .localFolder(folder)
        state.autosaveRecoveryStore = LocalAutosaveRecoveryStore(directory: root.appendingPathComponent("recovery"))
        let status = BoundaryCanvasStatus()
        let host = NSHostingView(rootView: BoundaryCanvas(fileState: state, status: status)
            .environment(\.managedObjectContext, context).environmentObject(AppPreference())
            .environmentObject(ExportState()).environmentObject(ToolState()).environmentObject(CanvasPreferencesState()))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }

        func open() async throws -> String {
            let start = Date()
            guard await state.requestActiveFileChange(.localFile(url)) else { throw CancellationError() }
            let id = try XCTUnwrap(state.currentActiveFile?.id)
            while state.excalidrawWebCoordinator?.documentSyncController.currentLoadedFileID != id {
                if let error = status.error { XCTFail(error); throw CancellationError() }
                guard Date().timeIntervalSince(start) < 45 else { XCTFail("load timeout"); throw CancellationError() }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            return id
        }
        func checkpointCount() throws -> Int {
            let request = NSFetchRequest<LocalFileCheckpoint>(entityName: "LocalFileCheckpoint")
            request.predicate = NSPredicate(format: "url == %@", url as NSURL)
            return try context.count(for: request)
        }

        // First open/close may normalize the hand-written file once.
        _ = try await open()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        _ = await state.requestActiveFileChange(nil)
        let normalized = try Data(contentsOf: url)
        let modified = try XCTUnwrap(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let checkpoints = try checkpointCount()

        // Viewing again without edits must not rewrite the file or add history.
        _ = try await open()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        _ = await state.requestActiveFileChange(nil)
        XCTAssertEqual(try Data(contentsOf: url), normalized)
        XCTAssertEqual(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
        XCTAssertEqual(try checkpointCount(), checkpoints)

        // An edit closed before its dirty notification arrives must still be saved.
        let id = try await open()
        let core = try XCTUnwrap(state.excalidrawWebCoordinator)
        let inspect = try await core.performDiagramCommand(["action": .string("inspect"), "document_id": .string(id), "limit": .number(1)])
        _ = try await core.performDiagramCommand([
            "action": .string("apply_operations"), "document_id": .string(id), "client_id": .string("boundary-test"),
            "expected_revision": inspect["revision"] ?? .null, "request_id": .string(UUID().uuidString),
            "operations": .array([.object(["type": .string("create"), "elements": .array([.object([
                "type": .string("ellipse"), "id": .string("unsignalled-edit"),
                "x": .number(300), "y": .number(300), "width": .number(40), "height": .number(40)])])])])
        ])
        _ = await state.requestActiveFileChange(nil)
        let saved = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(saved.contains("unsignalled-edit"), "a boundary save must persist edits that were not yet signalled")
        XCTAssertGreaterThan(try checkpointCount(), checkpoints)

        // An in-app move of the open file: a pending edit must land in the moved
        // file, and closing must not recreate the old path.
        let movedID = try await open()
        let movedCore = try XCTUnwrap(state.excalidrawWebCoordinator)
        let beforeMove = try await movedCore.performDiagramCommand(["action": .string("inspect"), "document_id": .string(movedID), "limit": .number(1)])
        _ = try await movedCore.performDiagramCommand([
            "action": .string("apply_operations"), "document_id": .string(movedID), "client_id": .string("boundary-test"),
            "expected_revision": beforeMove["revision"] ?? .null, "request_id": .string(UUID().uuidString),
            "operations": .array([.object(["type": .string("create"), "elements": .array([.object([
                "type": .string("diamond"), "id": .string("edit-before-move"),
                "x": .number(500), "y": .number(500), "width": .number(40), "height": .number(40)])])])])
        ])
        let moved = root.appendingPathComponent("moved.excalidraw")
        try FileManager.default.moveItem(at: url, to: moved)
        ExcalidrawFile.moveLocalFileID(from: url, to: moved)
        _ = await state.requestActiveFileChange(nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "closing must not resurrect a moved file")
        XCTAssertTrue(try String(contentsOf: moved, encoding: .utf8).contains("edit-before-move"), "pending edits follow the move")

    }
}

private final class BoundaryCanvasStatus: ObservableObject { var error: String? }

@MainActor
private struct BoundaryCanvas: View {
    @ObservedObject var fileState: FileState
    let status: BoundaryCanvasStatus
    @State private var scene: ExcalidrawFile?
    @State private var loading: ExcalidrawCanvasView.LoadingState = .loading
    var body: some View {
        ExcalidrawCanvasView(file: $scene, loadingState: $loading, onPersistSnapshot: { snapshot in
            try await fileState.persistAutosave(snapshot)
            guard fileState.currentActiveFile?.id == snapshot.id else { throw CancellationError() }
            scene = snapshot
        }, onError: { status.error = $0.localizedDescription })
        .environmentObject(fileState)
        .task(id: fileState.currentActiveFile?.id) {
            guard let active = fileState.currentActiveFile, case .localFile(let url) = active else { scene = nil; return }
            fileState.excalidrawWebCoordinator?.documentSyncController.setTargetFileID(active.id)
            do {
                let data = try await FileSyncCoordinator.shared.openFile(url)
                let opened = try await ExcalidrawFile.decodeForOpening(data: data, id: active.id)
                guard !Task.isCancelled, fileState.currentActiveFile?.id == active.id else { return }
                scene = opened
            } catch is CancellationError { return } catch { status.error = error.localizedDescription }
        }
    }
}
#endif
