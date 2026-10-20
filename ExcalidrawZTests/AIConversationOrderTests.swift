import XCTest
import CoreData
@testable import ExcalidrawZ

/// Updating an earlier message must not move it after later ones on restore.
final class AIConversationOrderTests: XCTestCase {
    func testUpdatedMessageKeepsItsPlace() async throws {
        let repository = PersistenceController.shared.aiConversationRepository
        let conversationID = "order-\(UUID().uuidString)"
        let conversation = try await repository.createConversation(conversationID: conversationID, title: "t", type: "normal")
        defer { Task { try? await repository.deleteConversation(conversationID: conversationID) } }

        let first = try await repository.createMessage(messageID: "first-\(conversationID)", messageType: "content", content: "a", role: "assistant", conversationObjectID: conversation)
        try await Task.sleep(nanoseconds: 20_000_000)
        _ = try await repository.createMessage(messageID: "second-\(conversationID)", messageType: "content", content: "b", role: "tool", conversationObjectID: conversation)
        try await Task.sleep(nanoseconds: 20_000_000)
        try await repository.updateMessage(messageObjectID: first, usageConsumed: 1, isCompactedOut: true)

        let snapshot = try await repository.fetchAllConversationSnapshots().first { $0.conversationID == conversationID }
        XCTAssertEqual(snapshot?.messages.map(\.messageID), ["first-\(conversationID)", "second-\(conversationID)"])
    }
}
