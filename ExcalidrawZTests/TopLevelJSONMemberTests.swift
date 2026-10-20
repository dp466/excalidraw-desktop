import XCTest
@testable import ExcalidrawZ

final class TopLevelJSONMemberTests: XCTestCase {
    private func value(_ json: String, _ key: String = "appState") -> String? {
        let data = Data(json.utf8)
        guard let member = TopLevelJSONMember.locate(key, in: data) else { return "nil" }
        return member.value(in: data).map { String(decoding: $0, as: UTF8.self) }
    }

    func testLocatesValueAcrossTrickyContent() {
        XCTAssertEqual(value(#"{"appState":{"a":1}}"#), #"{"a":1}"#)
        XCTAssertEqual(value(#" { "elements" : [ {"t":"}\"]{[", "n":[1,{"x":"\\"}]} ] ,"appState" : { "s" : "\"}" } , "z":null } "#), #"{ "s" : "\"}" }"#)
        XCTAssertEqual(value(#"{"x":"appState","appState":[1,2],"y":true}"#), "[1,2]")
        XCTAssertEqual(value(#"{"a":-1.5e3,"appState":false}"#), "false")
        XCTAssertEqual(value("{\n\t\"appState\"\r\n:\n\"\u{00e9}\u{1F600}\"\n}"), "\"\u{00e9}\u{1F600}\"")
        XCTAssertNil(value(#"{"elements":[]}"#))   // absent, not nil scan
        XCTAssertNil(value("{}"))
    }

    func testRefusesShapesItCannotWalkSafely() {
        XCTAssertEqual(value(#"[{"appState":1}]"#), "nil")
        XCTAssertEqual(value(#"{"appState":1} x"#), "nil")
        XCTAssertEqual(value(#"{"appState":1,"appState":2}"#), "nil")
        XCTAssertEqual(value(#"{"app\u0053tate":1}"#), "nil")
        XCTAssertEqual(value(#"{"appState":{"a":1}"#), "nil")
        XCTAssertEqual(value(#"{"appState":}"#), "nil")
        XCTAssertEqual(value(#"{"a":1,}"#), "nil")
    }

    func testReplacingAndAppendingKeepOtherMembers() throws {
        let replaced = try XCTUnwrap(TopLevelJSONMember.locate("appState", in: Data(#"{"e":[1],"appState":{"a":1},"f":{}}"#.utf8)))
            .replacingValue(in: Data(#"{"e":[1],"appState":{"a":1},"f":{}}"#.utf8), with: Data(#"{"b":2}"#.utf8), key: "appState")
        XCTAssertEqual(String(decoding: replaced, as: UTF8.self), #"{"e":[1],"appState":{"b":2},"f":{}}"#)

        let source = Data(#"{"e":[1]}"#.utf8)
        let appended = try XCTUnwrap(TopLevelJSONMember.locate("appState", in: source))
            .replacingValue(in: source, with: Data("{}".utf8), key: "appState")
        XCTAssertEqual(String(decoding: appended, as: UTF8.self), #"{"e":[1],"appState":{}}"#)

        let empty = Data(" { } ".utf8)
        let filled = try XCTUnwrap(TopLevelJSONMember.locate("appState", in: empty))
            .replacingValue(in: empty, with: Data("{}".utf8), key: "appState")
        XCTAssertEqual(String(decoding: filled, as: UTF8.self), #" { "appState":{}} "#)

        // Slices keep their own indices.
        let padded = Data(#"xx{"appState":{"a":1}}"#.utf8).dropFirst(2)
        let sliced = try XCTUnwrap(TopLevelJSONMember.locate("appState", in: padded))
        XCTAssertEqual(sliced.value(in: padded).map { String(decoding: $0, as: UTF8.self) }, #"{"a":1}"#)
    }
}
