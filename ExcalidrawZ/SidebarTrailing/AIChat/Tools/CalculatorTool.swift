//
//  CalculatorTool.swift
//  AIppo
//
//  Created by Claude Code
//

import Foundation
import LLMCore

/// Simple calculator tool for basic math operations
struct CalculatorTool: Tool {
    var name: String { "calculator" }

    var displayName: String { String(localizable: .aiChatToolCalculatorName) }

    var description: String {
        "Perform basic mathematical calculations. Supports +, -, *, /, ^, sqrt, sin, cos, tan, log, ln, and parentheses."
    }

    var inputSchema: ToolInputSchema {
        .parameters(ToolParameters(
            properties: [
                "expression": ParameterProperty(
                    type: "string",
                    description: "The mathematical expression to evaluate (e.g., '2 + 2', 'sqrt(16)', 'sin(3.14159/2)')"
                )
            ],
            required: ["expression"]
        ))
    }

    func execute(_ input: String, context: (any ChatInvocationContext)?) async throws -> ToolResult {
        try AIChatToolExecutionGate.ensureAIEnabled()

        // Parse input JSON
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expression = json["expression"] as? String else {
            throw ToolError.invalidInput("Invalid input format. Expected: {\"expression\": \"2 + 2\"}")
        }

        do {
            let result = try evaluate(expression)
            return .text("Result: \(result)")
        } catch {
            throw ToolError.executionFailed("Failed to evaluate expression: \(error.localizedDescription)")
        }
    }

    private func evaluate(_ expression: String) throws -> Double {
        // NSExpression(format:) raised uncatchable Objective-C exceptions on
        // malformed input (crashing the app) and its FUNCTION/CAST syntax
        // can invoke arbitrary methods; model input gets a plain parser.
        var parser = ArithmeticParser(expression)
        let result = try parser.parse()
        guard result.isFinite else {
            throw ToolError.executionFailed("Result is not a finite number")
        }
        return result
    }
}

/// Recursive-descent evaluator for + - * / ^ (or **), parentheses, unary
/// signs, the constants pi and e, and sqrt, abs, sin, cos, tan, log, ln.
struct ArithmeticParser {
    private let scalars: [Character]
    private var index = 0
    private var depth = 0

    init(_ expression: String) {
        scalars = Array(expression)
    }

    mutating func parse() throws -> Double {
        let value = try parseSum()
        skipSpaces()
        guard index == scalars.count else {
            throw ToolError.executionFailed("Unexpected '\(scalars[index])' in expression")
        }
        return value
    }

    private mutating func parseSum() throws -> Double {
        var value = try parseProduct()
        while true {
            skipSpaces()
            if consume("+") {
                value += try parseProduct()
            } else if consume("-") {
                value -= try parseProduct()
            } else {
                return value
            }
        }
    }

    private mutating func parseProduct() throws -> Double {
        var value = try parsePower()
        while true {
            skipSpaces()
            if peek("*"), !peek("**") {
                index += 1
                value *= try parsePower()
            } else if consume("/") {
                value /= try parsePower()
            } else {
                return value
            }
        }
    }

    private mutating func parsePower() throws -> Double {
        let base = try parseUnary()
        skipSpaces()
        if consume("^") || consume("**") {
            // Right-associative: 2^3^2 = 2^(3^2).
            return pow(base, try parsePower())
        }
        return base
    }

    private mutating func parseUnary() throws -> Double {
        skipSpaces()
        if consume("-") { return -(try parseUnary()) }
        if consume("+") { return try parseUnary() }
        return try parsePrimary()
    }

    private mutating func parsePrimary() throws -> Double {
        skipSpaces()
        depth += 1
        defer { depth -= 1 }
        guard depth < 200 else {
            throw ToolError.executionFailed("Expression is nested too deeply")
        }

        if consume("(") {
            let value = try parseSum()
            skipSpaces()
            guard consume(")") else { throw ToolError.executionFailed("Missing ')'") }
            return value
        }

        if index < scalars.count, scalars[index].isNumber || scalars[index] == "." {
            let start = index
            while index < scalars.count, scalars[index].isNumber || scalars[index] == "." {
                index += 1
            }
            if index < scalars.count, scalars[index] == "e" || scalars[index] == "E" {
                var lookahead = index + 1
                if lookahead < scalars.count, scalars[lookahead] == "+" || scalars[lookahead] == "-" {
                    lookahead += 1
                }
                if lookahead < scalars.count, scalars[lookahead].isNumber {
                    index = lookahead
                    while index < scalars.count, scalars[index].isNumber { index += 1 }
                }
            }
            guard let value = Double(String(scalars[start..<index])) else {
                throw ToolError.executionFailed("Invalid number '\(String(scalars[start..<index]))'")
            }
            return value
        }

        if index < scalars.count, scalars[index].isLetter {
            let start = index
            while index < scalars.count, scalars[index].isLetter || scalars[index].isNumber {
                index += 1
            }
            let name = String(scalars[start..<index]).lowercased()
            switch name {
                case "pi": return Double.pi
                case "e": return M_E
                default: break
            }
            skipSpaces()
            guard consume("(") else {
                throw ToolError.executionFailed("Unknown name '\(name)'")
            }
            let argument = try parseSum()
            skipSpaces()
            guard consume(")") else { throw ToolError.executionFailed("Missing ')'") }
            switch name {
                case "sqrt": return argument.squareRoot()
                case "abs": return abs(argument)
                case "sin": return sin(argument)
                case "cos": return cos(argument)
                case "tan": return tan(argument)
                case "log": return log10(argument)
                case "ln": return log(argument)
                default: throw ToolError.executionFailed("Unsupported function '\(name)'")
            }
        }

        throw ToolError.executionFailed(
            index < scalars.count ? "Unexpected '\(scalars[index])'" : "Unexpected end of expression"
        )
    }

    private mutating func skipSpaces() {
        while index < scalars.count, scalars[index].isWhitespace { index += 1 }
    }

    private func peek(_ token: String) -> Bool {
        let characters = Array(token)
        guard index + characters.count <= scalars.count else { return false }
        return Array(scalars[index..<(index + characters.count)]) == characters
    }

    private mutating func consume(_ token: String) -> Bool {
        guard peek(token) else { return false }
        index += token.count
        return true
    }
}
