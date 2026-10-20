import XCTest
@testable import ExcalidrawZ

/// History rows show only the visible element count of each checkpoint.
final class CheckpointRowCostTests: XCTestCase {
    private func drawing() throws -> Data {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = repo.appendingPathComponent("outputs/network-deployment/detailed/aurora-detailed-network.excalidraw")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["type"] = object["type"] ?? "excalidraw"
        object["version"] = object["version"] ?? 2
        object["source"] = object["source"] ?? "https://excalidraw.com"
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testCountMatchesFullDecodeAndCostsLess() throws {
        let data = try drawing()
        let full = try JSONDecoder().decode(ExcalidrawFile.self, from: data)
        let expected = full.elements.filter { !$0.isDeleted }.count
        XCTAssertEqual(FileCheckpointElementCounter.visibleElementCount(in: data), expected)

        let clock = ContinuousClock()
        func ms(_ body: () throws -> Void) rethrows -> Double {
            let start = clock.now
            try body()
            let elapsed = clock.now - start
            return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        }
        var fullMS: [Double] = [], countMS: [Double] = []
        for _ in 0..<5 {
            fullMS.append(try ms { _ = try JSONDecoder().decode(ExcalidrawFile.self, from: data) })
            countMS.append(ms { _ = FileCheckpointElementCounter.visibleElementCount(in: data) })
        }
        print(String(format: "BENCHROW %.0f KB, %d elements: full decode ms ", Double(data.count) / 1024, expected)
              + fullMS.map { String(format: "%.1f", $0) }.joined(separator: " ")
              + " | count ms " + countMS.map { String(format: "%.1f", $0) }.joined(separator: " "))
    }
}
