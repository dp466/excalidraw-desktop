import Foundation
import XCTest
@testable import ExcalidrawZ

/// Uses disposable temporary folders only.
final class FileSyncCoordinatorTests: XCTestCase {
    func testEverySubscriberReceivesEventsAndEndingOneKeepsTheOther() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let coordinator = FileSyncCoordinator.shared
        try await coordinator.addFolder(at: folder, options: .default)

        let first = expectation(description: "first window sees the change")
        first.assertForOverFulfill = false
        let firstTask = Task {
            for await event in await coordinator.fileChangesStream where Self.matches(event, folder) {
                first.fulfill()
                break
            }
        }
        let second = expectation(description: "second window sees later changes")
        second.assertForOverFulfill = false
        let secondTask = Task {
            for await event in await coordinator.fileChangesStream where Self.matches(event, folder) {
                second.fulfill()
            }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("a.excalidraw"))
        await fulfillment(of: [first, second], timeout: 10)

        // The first subscriber has ended; the second must keep receiving events.
        _ = await firstTask.value
        try await Task.sleep(nanoseconds: 300_000_000)
        let afterEnd = expectation(description: "second window still receives events")
        afterEnd.assertForOverFulfill = false
        let watcher = Task {
            for await event in await coordinator.fileChangesStream where Self.matches(event, folder) {
                afterEnd.fulfill()
                break
            }
        }
        try Data("{}".utf8).write(to: folder.appendingPathComponent("b.excalidraw"))
        await fulfillment(of: [afterEnd], timeout: 10)
        secondTask.cancel()
        watcher.cancel()
        await coordinator.removeFolder(at: folder)
    }

    func testSecondWindowSharesMonitorAndFirstCloseKeepsIt() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let coordinator = FileSyncCoordinator.shared
        try await coordinator.addFolder(at: folder, options: .default)
        try await coordinator.addFolder(at: folder, options: .default) // second window: no alreadyMonitoring error
        let count = await coordinator.registrationCount(for: folder)
        XCTAssertEqual(count, 2)
        await coordinator.removeFolder(at: folder)
        let afterOne = await coordinator.registrationCount(for: folder)
        XCTAssertEqual(afterOne, 1, "closing one window must not stop the other's monitor")

        let event = expectation(description: "remaining window still notified")
        event.assertForOverFulfill = false
        let task = Task {
            for await change in await coordinator.fileChangesStream where Self.matches(change, folder) {
                event.fulfill()
                break
            }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("c.excalidraw"))
        await fulfillment(of: [event], timeout: 10)
        task.cancel()
        await coordinator.removeFolder(at: folder)
        let afterAll = await coordinator.registrationCount(for: folder)
        XCTAssertEqual(afterAll, 0)
    }

    func testCoordinatedWritesKeepCallOrder() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("ordered.excalidraw")
        // Concurrent writers must all complete without blocking each other.
        let writes = (0..<40).map { index in
            Task { try await FileCoordinator.shared.coordinatedWrite(url: url, data: Data("\(index)".utf8)) }
        }
        for task in writes { try await task.value }
        for index in 0..<25 {
            try await FileCoordinator.shared.coordinatedWrite(url: url, data: Data("seq-\(index)".utf8))
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "seq-24")
        let data = try await FileCoordinator.shared.coordinatedRead(url: url)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "seq-24")
    }

    private static func matches(_ event: FSChangeEvent, _ folder: URL) -> Bool {
        let path: String
        switch event {
        case .created(let url), .modified(let url), .deleted(let url): path = url.resolvingSymlinksInPath().path
        case .renamed(_, let url): path = url.resolvingSymlinksInPath().path
        case .statusChanged(let url, _): path = url.resolvingSymlinksInPath().path
        }
        return path.hasPrefix(folder.resolvingSymlinksInPath().path)
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("fsc-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
