//
//  MCPJSONValue.swift
//  ExcalidrawZ
//
//  Created by Codex on 2026/06/14.
//

import Foundation

enum MCPJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([MCPJSONValue])
    case object([String: MCPJSONValue])

    init(from decoder: Decoder) throws {
        if var container = try? decoder.unkeyedContainer() {
            var values: [MCPJSONValue] = []
            while !container.isAtEnd {
                values.append(try container.decode(MCPJSONValue.self))
            }
            self = .array(values)
            return
        }

        if let container = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            var object: [String: MCPJSONValue] = [:]
            for key in container.allKeys {
                object[key.stringValue] = try container.decode(MCPJSONValue.self, forKey: key)
            }
            self = .object(object)
            return
        }

        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
            case .null:
                var container = encoder.singleValueContainer()
                try container.encodeNil()
            case .bool(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .number(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .string(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .array(let values):
                var container = encoder.unkeyedContainer()
                for value in values {
                    try container.encode(value)
                }
            case .object(let object):
                var container = encoder.container(keyedBy: DynamicCodingKey.self)
                for key in object.keys.sorted() {
                    try container.encode(object[key], forKey: DynamicCodingKey(key))
                }
        }
    }

    init(jsonObject: Any) throws {
        switch jsonObject {
            case is NSNull:
                self = .null
            case let value as NSNumber:
                if CFGetTypeID(value) == CFBooleanGetTypeID() {
                    self = .bool(value.boolValue)
                } else {
                    self = .number(value.doubleValue)
                }
            case let value as Bool:
                self = .bool(value)
            case let value as Int:
                self = .number(Double(value))
            case let value as Double:
                self = .number(value)
            case let value as String:
                self = .string(value)
            case let array as [Any]:
                self = .array(try array.map(MCPJSONValue.init(jsonObject:)))
            case let dictionary as [String: Any]:
                self = .object(try dictionary.mapValues { try MCPJSONValue(jsonObject: $0) })
            default:
                throw MCPJSONValueError.unsupportedValue
        }
    }

    var objectValue: [String: MCPJSONValue]? {
        guard case .object(let object) = self else { return nil }
        return object
    }

    var arrayValue: [MCPJSONValue]? {
        guard case .array(let values) = self else { return nil }
        return values
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    subscript(key: String) -> MCPJSONValue? {
        objectValue?[key]
    }

    static func parseJSONArray(from data: Data) throws -> [MCPJSONValue] {
        try validateStrictJSONSyntax(data)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let array = object as? [Any] else {
            throw MCPJSONValueError.expectedArray
        }
        return try array.map(MCPJSONValue.init(jsonObject:))
    }

    static func parse(from data: Data) throws -> MCPJSONValue {
        try MCPJSONValue(jsonObject: JSONSerialization.jsonObject(with: data))
    }

    private static func validateStrictJSONSyntax(_ data: Data) throws {
        guard let string = String(data: data, encoding: .utf8) else {
            throw MCPJSONValueError.invalidUTF8
        }

        var isInString = false
        var isEscaped = false
        var pendingComma = false

        for scalar in string.unicodeScalars {
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if scalar == "\\" {
                    isEscaped = true
                } else if scalar == "\"" {
                    isInString = false
                }
                continue
            }

            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            }

            if pendingComma {
                if scalar == "]" || scalar == "}" {
                    throw MCPJSONValueError.trailingComma
                }
                pendingComma = false
            }

            if scalar == "\"" {
                isInString = true
            } else if scalar == "," {
                pendingComma = true
            }
        }
    }
}

private enum MCPJSONValueError: LocalizedError {
    case expectedArray
    case invalidUTF8
    case trailingComma
    case unsupportedValue

    var errorDescription: String? {
        switch self {
            case .expectedArray:
                "Expected a JSON array."
            case .invalidUTF8:
                "JSON input must be valid UTF-8."
            case .trailingComma:
                "JSON input must not contain trailing commas."
            case .unsupportedValue:
                "Unsupported JSON value."
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

extension MCPJSONValue {
    /// `Int(_: Double)` traps outside Int's range, and MCP clients may send any
    /// finite JSON number, such as 1e20.
    static func integerText(_ number: Double) -> String {
        if number.rounded(.towardZero) == number, abs(number) < 9_007_199_254_740_992 {
            return String(Int(number))
        }
        return String(number)
    }

    static func clampedInteger(_ number: Double?, default fallback: Int, in range: ClosedRange<Int>) -> Int {
        guard let number, number.isFinite else { return fallback }
        return Int(min(max(number.rounded(.towardZero), Double(range.lowerBound)), Double(range.upperBound)))
    }
}
