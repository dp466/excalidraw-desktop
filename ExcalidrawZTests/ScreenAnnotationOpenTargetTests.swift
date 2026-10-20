#if os(macOS)
import XCTest
import AppKit
import CoreData
import SwiftUI
@testable import ExcalidrawZ

/// Saving a screen annotation into the drawing that is open in the editor.
/// Real bundled editor, disposable folder, in-memory database.
@MainActor
final class ScreenAnnotationOpenTargetTests: XCTestCase {
    private let defaultsKeys = ["ScreenAnnotationRecentFileDestinations", "ScreenAnnotationSavePreferences"]

    func testAnnotationInsertedIntoOpenDrawingSurvivesLeavingIt() async throws {
        let stores = PersistenceController.shared.container.persistentStoreCoordinator.persistentStores
        XCTAssertTrue(AppRuntime.isRunningTests && stores.allSatisfy { $0.type == NSInMemoryStoreType })
        // The save records recent destinations in the host's defaults; restore them.
        let savedDefaults = defaultsKeys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(defaultsKeys, savedDefaults) {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("annotation-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = PersistenceController.shared.container.viewContext
        let folder = try LocalFolder(url: root, context: context)
        try context.save()
        let url = root.appendingPathComponent("open.excalidraw")
        try JSONSerialization.data(withJSONObject: Self.scene(elementID: "existing", x: 10)).write(to: url)

        let state = FileState()
        state.currentActiveGroup = .localFolder(folder)
        state.autosaveRecoveryStore = LocalAutosaveRecoveryStore(directory: root.appendingPathComponent("recovery"))
        let status = AnnotationCanvasStatus()
        let host = NSHostingView(rootView: AnnotationCanvas(fileState: state, status: status)
            .environment(\.managedObjectContext, context).environmentObject(AppPreference())
            .environmentObject(ExportState()).environmentObject(ToolState()).environmentObject(CanvasPreferencesState()))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }

        let start = Date()
        guard await state.requestActiveFileChange(.localFile(url)) else { return XCTFail("open") }
        let id = try XCTUnwrap(state.currentActiveFile?.id)
        while state.excalidrawWebCoordinator?.documentSyncController.currentLoadedFileID != id {
            if let error = status.error { return XCTFail(error) }
            guard Date().timeIntervalSince(start) < 45 else { return XCTFail("load timeout") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // Annotation documents carry one marked frame around their content.
        var annotationScene = Self.scene(elementID: "screen-annotation-mark", x: 400)
        var mark = (annotationScene["elements"] as! [[String: Any]])[0]
        mark["frameId"] = "screen-annotation-frame"
        var frame = mark
        frame["id"] = "screen-annotation-frame"
        frame["type"] = "frame"
        frame["frameId"] = NSNull()
        frame["name"] = "Annotation"
        frame["x"] = 380; frame["y"] = 0; frame["width"] = 200; frame["height"] = 120
        frame["customData"] = ["excalidrawZScreenAnnotation": true]
        annotationScene["elements"] = [frame, mark]
        let annotation = try ExcalidrawFile(
            data: JSONSerialization.data(withJSONObject: annotationScene),
            id: "annotation"
        )
        let persistence = ScreenAnnotationSavePersistence(configuration: ScreenAnnotationSaveConfiguration())
        try await persistence.persist(
            .document(document: annotation, destination: .localFile(url: url), fileState: state, customLocationURL: nil),
            saveID: "open-target-test"
        )
        // Insertion assigns new element IDs; count the frames on disk instead.
        func liveFrames() throws -> Int {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            let elements = object?["elements"] as? [[String: Any]] ?? []
            return elements.filter { $0["type"] as? String == "frame" && $0["isDeleted"] as? Bool != true }.count
        }
        XCTAssertEqual(try liveFrames(), 1, "the annotation is saved")

        // Leaving the drawing runs the boundary save of the open editor.
        _ = await state.requestActiveFileChange(nil)
        let saved = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(try liveFrames(), 1, "leaving the drawing must not overwrite the annotation")
        XCTAssertTrue(saved.contains("existing"))
    }

    private static func scene(elementID: String, x: Double) -> [String: Any] {
        [
            "type": "excalidraw", "version": 2, "source": "https://excalidraw.com",
            "elements": [[
                "id": elementID, "type": "rectangle", "x": x, "y": 20, "width": 120, "height": 60, "angle": 0,
                "strokeColor": "#1e1e1e", "backgroundColor": "transparent", "fillStyle": "solid", "strokeWidth": 2,
                "strokeStyle": "solid", "roughness": 1, "opacity": 100, "groupIds": [String](), "frameId": NSNull(),
                "roundness": NSNull(), "seed": 1, "version": 1, "versionNonce": 1, "isDeleted": false,
                "boundElements": NSNull(), "updated": 1, "link": NSNull(), "locked": false,
            ]],
            "appState": ["viewBackgroundColor": "#ffffff"], "files": [String: Any](),
        ]
    }
}

private final class AnnotationCanvasStatus: ObservableObject { var error: String? }

@MainActor
private struct AnnotationCanvas: View {
    @ObservedObject var fileState: FileState
    let status: AnnotationCanvasStatus
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
