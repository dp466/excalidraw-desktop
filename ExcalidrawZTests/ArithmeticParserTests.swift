import XCTest
@testable import ExcalidrawZ

/// The AI calculator tool evaluates model-supplied text. Malformed input must
/// throw instead of crashing, and NSExpression syntax must not run.
final class ArithmeticParserTests: XCTestCase {
    private func evaluate(_ expression: String) throws -> Double {
        var parser = ArithmeticParser(expression)
        return try parser.parse()
    }

    func testEvaluatesArithmetic() throws {
        XCTAssertEqual(try evaluate("2 + 3 * 4"), 14)
        XCTAssertEqual(try evaluate("(2 + 3) * 4"), 20)
        XCTAssertEqual(try evaluate("2 ^ 3 ^ 2"), 512)
        XCTAssertEqual(try evaluate("2 ** 10"), 1024)
        XCTAssertEqual(try evaluate("-3 + +5"), 2)
        XCTAssertEqual(try evaluate("10 / 4"), 2.5)
        XCTAssertEqual(try evaluate("1.5e2"), 150)
        XCTAssertEqual(try evaluate("sqrt(16) + abs(-2)"), 6)
        XCTAssertEqual(try evaluate("ln(e)"), 1, accuracy: 1e-12)
        XCTAssertEqual(try evaluate("log(1000)"), 3, accuracy: 1e-12)
        XCTAssertEqual(try evaluate("sin(pi / 2)"), 1, accuracy: 1e-12)
    }

    func testRejectsMalformedAndUnsafeInput() {
        for expression in [
            "2 +",
            "(1 + 2",
            "",
            "foo(1)",
            "x + 1",
            "FUNCTION(CAST('NSTask', 'Class'), 'new')",
            "1 2",
            String(repeating: "(", count: 500) + "1" + String(repeating: ")", count: 500),
        ] {
            XCTAssertThrowsError(try evaluate(expression), expression)
        }
    }
}
