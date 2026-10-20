import XCTest
@testable import ExcalidrawZ

/// A new drawing's image must wait for that drawing, never land in another.
@MainActor
final class InsertImageTargetTests: XCTestCase {
    func testInsertGivesUpWhenEditorNeverShowsTheFile() async {
        let state = FileState()
        let start = Date()
        do {
            try await state.insertImage(Data([0x89]), type: "png", intoFileWithID: "not-open", timeout: 0.3)
            XCTFail("must not insert while another file is shown")
        } catch let AppError.stateError(error) {
            XCTAssertEqual(error, .editorNotShowingFile)
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.3)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
