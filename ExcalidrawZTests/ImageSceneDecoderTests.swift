import XCTest
@testable import ExcalidrawZ

/// PNG/SVG scene decoders read files from linked folders and Quick Look.
final class ImageSceneDecoderTests: XCTestCase {
    private let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    private func chunk(_ type: String, _ payload: Data, declaredLength: UInt32? = nil) -> Data {
        var data = Data()
        var length = (declaredLength ?? UInt32(payload.count)).bigEndian
        data.append(Data(bytes: &length, count: 4))
        data.append(Data(type.utf8))
        data.append(payload)
        data.append(Data([0, 0, 0, 0]))
        return data
    }

    func testTruncatedAndOversizedChunksDoNotCrash() {
        // Header only, a chunk cut short, and a chunk claiming more bytes than exist.
        XCTAssertNil(ExcalidrawPNGDecoder().decode(from: pngSignature + Data([0, 0])))
        XCTAssertNil(ExcalidrawPNGDecoder().decode(from: pngSignature + chunk("IHDR", Data(count: 13)).prefix(10)))
        XCTAssertNil(ExcalidrawPNGDecoder().decode(from: pngSignature + chunk("tEXt", Data("a".utf8), declaredLength: 4_000_000)))
        XCTAssertNil(ExcalidrawPNGDecoder().decode(from: pngSignature + chunk("tEXt", Data("a".utf8), declaredLength: UInt32.max)))
    }

    func testSceneInTextChunkIsDecoded() throws {
        let scene = #"{"type":"excalidraw","version":2,"source":"test","elements":[],"appState":{},"files":{}}"#
        let text = Data("application/vnd.excalidraw+json".utf8) + Data([0]) + Data(scene.utf8)
        let png = pngSignature + chunk("IHDR", Data(count: 13)) + chunk("tEXt", text) + chunk("IEND", Data())
        XCTAssertNotNil(ExcalidrawPNGDecoder().decode(from: png))
    }

    func testLargeSVGPayloadDecodesQuickly() {
        let payload = Data(repeating: UInt8(ascii: "a"), count: 300_000).base64EncodedString()
        let svg = """
        <svg><!-- svg-source:excalidraw --><!-- payload-type:application/vnd.excalidraw+json -->\
        <!-- payload-version:2 --><!-- payload-start -->\(payload)<!-- payload-end --></svg>
        """
        let start = Date()
        XCTAssertNil(ExcalidrawSVGDecoder().decode(from: Data(svg.utf8)))
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "BENCHSVG 300 KB payload decode %.3f s", elapsed))
        XCTAssertLessThan(elapsed, 2)
    }
}
