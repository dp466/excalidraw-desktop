import XCTest
@testable import ExcalidrawZ

/// The editor posts save-stream messages in order on the main thread; the
/// assembled document must keep that order and never finish short.
@MainActor
final class SaveStreamOrderingTests: XCTestCase {
    private typealias Core = ExcalidrawCore

    private func decode<T: Decodable>(_ object: [String: Any]) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func document(bytes: Int) -> Data {
        var data = Data(capacity: bytes)
        var counter = 0
        while data.count < bytes {
            data.append(contentsOf: Array("{\"id\":\"element-\(counter)\",\"x\":\(counter)}".utf8))
            counter += 1
        }
        return data.prefix(bytes)
    }

    private func post(
        _ data: Data,
        to bridge: Core.CurrentFileSaveStreamBridge,
        streamID: String,
        chunkSize: Int = 65_536,
        droppingLastChunk: Bool = false
    ) throws {
        bridge.receiveStarted(try decode(["streamId": streamID, "totalBytes": data.count]))
        var chunks: [Data] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            chunks.append(data.subdata(in: offset..<end))
            offset = end
        }
        if droppingLastChunk { chunks.removeLast() }
        for (index, chunk) in chunks.enumerated() {
            bridge.receiveChunk(try decode([
                "streamId": streamID, "index": index, "base64": chunk.base64EncodedString()
            ]))
        }
        bridge.receiveFinished(try decode(["streamId": streamID, "totalBytes": data.count]))
    }

    func testStreamKeepsPostedOrder() async throws {
        let original = document(bytes: 2_000_000)
        for round in 0..<20 {
            let bridge = Core.CurrentFileSaveStreamBridge()
            let streamID = "ordering-\(round)"
            try await bridge.openStream(streamID: streamID)
            try post(original, to: bridge, streamID: streamID, chunkSize: 16_384)
            let result = try await bridge.awaitStream(streamID: streamID, timeoutNanoseconds: 10_000_000_000)
            XCTAssertEqual(result.documentData, original, "round \(round)")
        }
    }

    func testStreamShortOfTotalBytesFails() async throws {
        let bridge = Core.CurrentFileSaveStreamBridge()
        try await bridge.openStream(streamID: "short")
        try post(document(bytes: 200_000), to: bridge, streamID: "short", droppingLastChunk: true)
        do {
            let result = try await bridge.awaitStream(streamID: "short", timeoutNanoseconds: 5_000_000_000)
            XCTFail("Truncated stream returned \(result.documentData.count) bytes")
        } catch {}
    }

    func testStreamAssemblyCost() async throws {
        let original = document(bytes: 6_600_000)
        let clock = ContinuousClock()
        var durations: [Duration] = []
        for round in 0..<5 {
            let bridge = Core.CurrentFileSaveStreamBridge()
            let streamID = "cost-\(round)"
            try await bridge.openStream(streamID: streamID)
            let start = clock.now
            try post(original, to: bridge, streamID: streamID)
            let result = try await bridge.awaitStream(streamID: streamID, timeoutNanoseconds: 30_000_000_000)
            durations.append(clock.now - start)
            XCTAssertEqual(result.documentData.count, original.count)
        }
        let ms = durations.map { Double($0.components.attoseconds) / 1e15 + Double($0.components.seconds) * 1000 }
        print("BENCHSTREAM 6.6 MB assembly ms: " + ms.map { String(format: "%.1f", $0) }.joined(separator: " "))
    }
}
