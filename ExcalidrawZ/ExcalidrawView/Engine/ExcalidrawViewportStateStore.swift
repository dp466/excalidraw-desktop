//
//  ExcalidrawViewportStateStore.swift
//  ExcalidrawZ
//
//  Created by Codex on 2026/06/30.
//

import CryptoKit
import Foundation

struct ExcalidrawViewportState: Codable, Equatable, Sendable {
    var values: [String: ExcalidrawCore.JSONValue]

    var isEmpty: Bool {
        values.isEmpty
    }
}

/// Stores device-local viewport state outside the synced Excalidraw file JSON.
///
/// Excalidraw keeps `scrollX`, `scrollY`, and `zoom` in appState, but those
/// values describe the current device/window rather than collaborative file
/// content. Keeping them in a local sidecar lets opening transitions reuse the
/// last viewport without letting one device's scroll position overwrite another
/// device's file content through iCloud Drive.
actor ExcalidrawViewportStateStore {
    static let shared = ExcalidrawViewportStateStore()

    private struct StoredViewportState: Codable {
        var fileID: String
        var updatedAt: Date
        var viewport: ExcalidrawViewportState
    }

    private struct JSONValueWrapper: Codable {
        var value: ExcalidrawCore.JSONValue
    }

    private static let storedViewportKeys: Set<String> = [
        "scrollX",
        "scrollY",
        "zoom"
    ]

    private static let strippedViewportKeys: Set<String> = [
        "scrollX",
        "scrollY",
        "zoom",
        "width",
        "height"
    ]

    /// Last viewport written or read per file, so unchanged autosaves do not
    /// rewrite the sidecar.
    private var knownViewports: [String: ExcalidrawViewportState] = [:]

    private init() {}

    func contentDataByApplyingStoredViewport(
        to data: Data,
        fileID: String
    ) async throws -> Data {
        guard let storedViewport = try load(fileID: fileID) else {
            if let viewport = try Self.viewport(fromContentData: data) {
                try save(viewport, fileID: fileID)
                return try Self.contentDataByApplyingViewport(
                    viewport,
                    to: data
                )
            }
            return data
        }

        return try Self.contentDataByApplyingViewport(
            storedViewport,
            to: data
        )
    }

    func contentDataBySeparatingViewport(
        from data: Data,
        fileID: String
    ) async throws -> Data {
        // One scan serves both the sidecar value and the stripped document.
        if let member = TopLevelJSONMember.locate("appState", in: data) {
            guard let valueData = member.value(in: data),
                  var appState = try JSONSerialization.jsonObject(
                    with: valueData,
                    options: .fragmentsAllowed
                  ) as? [String: Any] else {
                return data
            }
            if let viewport = try Self.viewport(fromAppStateObject: appState) {
                try save(viewport, fileID: fileID)
            }
            guard Self.strippedViewportKeys.contains(where: { appState[$0] != nil }) else {
                return data
            }
            for key in Self.strippedViewportKeys {
                appState.removeValue(forKey: key)
            }
            return try member.replacingValue(
                in: data,
                with: JSONSerialization.data(withJSONObject: appState),
                key: "appState"
            )
        }
        if let viewport = try Self.viewport(fromContentData: data) {
            try save(viewport, fileID: fileID)
        }
        return try Self.contentDataByRemovingViewport(from: data)
    }

    /// Applies the viewport currently visible in the WebView to replacement
    /// document data. This keeps a same-document refresh from jumping back to
    /// the last debounced sidecar value.
    func contentData(
        _ data: Data,
        preservingViewportFrom appState: ExcalidrawCore.JSONValue,
        sidecarFileID: String?
    ) throws -> Data? {
        guard let viewport = try Self.viewport(
            fromAppStateObject: appState.foundationObject
        ) else {
            return nil
        }

        if let sidecarFileID {
            try save(viewport, fileID: sidecarFileID)
        }
        return try Self.contentDataByApplyingViewport(viewport, to: data)
    }

    /// Preserves the source document's viewport while accepting all other
    /// appState changes from an editor running at a different offscreen size.
    func contentData(
        _ data: Data,
        preservingViewportFrom sourceData: Data
    ) throws -> Data {
        let dataWithoutViewport = try Self.contentDataByRemovingViewport(
            from: data
        )
        guard let viewport = try Self.viewport(fromContentData: sourceData) else {
            return dataWithoutViewport
        }
        return try Self.contentDataByApplyingViewport(
            viewport,
            to: dataWithoutViewport
        )
    }

    func appStateBySeparatingViewport(
        _ appState: ExcalidrawCore.JSONValue,
        fileID: String
    ) async throws -> ExcalidrawCore.JSONValue {
        let appStateObject = appState.foundationObject
        if let viewport = try Self.viewport(fromAppStateObject: appStateObject) {
            try save(viewport, fileID: fileID)
        }

        let strippedObject = Self.appStateObjectByRemovingViewport(from: appStateObject)
        return try Self.jsonValue(from: strippedObject)
    }

    private func save(_ viewport: ExcalidrawViewportState, fileID: String) throws {
        guard !viewport.isEmpty, knownViewports[fileID] != viewport else { return }

        let stored = StoredViewportState(
            fileID: fileID,
            updatedAt: Date(),
            viewport: viewport
        )
        let data = try JSONEncoder().encode(stored)
        try data.write(to: fileURL(for: fileID), options: .atomic)
        knownViewports[fileID] = viewport
    }

    private func load(fileID: String) throws -> ExcalidrawViewportState? {
        let url = try fileURL(for: fileID)
        guard FileManager.default.fileExists(atPath: url.filePath) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        let stored = try JSONDecoder().decode(StoredViewportState.self, from: data)
        knownViewports[fileID] = stored.viewport
        return stored.viewport
    }

    private func fileURL(for fileID: String) throws -> URL {
        let directory = try storageDirectoryURL()
        let filename = Self.filename(for: fileID)
        return directory.appendingPathComponent(filename).appendingPathExtension("json")
    }

    private func storageDirectoryURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport
            .appendingPathComponent("ViewportState", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return directory
    }

    private static func filename(for fileID: String) -> String {
        let digest = SHA256.hash(data: Data(fileID.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func viewport(fromContentData data: Data) throws -> ExcalidrawViewportState? {
        if let member = TopLevelJSONMember.locate("appState", in: data) {
            guard case .found(let valueRange, _) = member else { return nil }
            return try viewport(fromAppStateObject: try JSONSerialization.jsonObject(
                with: data.subdata(in: valueRange),
                options: .fragmentsAllowed
            ))
        }
        guard let contentObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let appStateObject = contentObject["appState"] else {
            return nil
        }

        return try viewport(fromAppStateObject: appStateObject)
    }

    private static func viewport(fromAppStateObject appStateObject: Any) throws -> ExcalidrawViewportState? {
        guard let appState = appStateObject as? [String: Any] else {
            return nil
        }

        var values: [String: ExcalidrawCore.JSONValue] = [:]
        for key in storedViewportKeys {
            guard let value = appState[key],
                  !(value is NSNull) else {
                continue
            }
            values[key] = try jsonValue(from: value)
        }

        guard !values.isEmpty else { return nil }
        return ExcalidrawViewportState(values: values)
    }

    private static func contentDataByApplyingViewport(
        _ viewport: ExcalidrawViewportState,
        to data: Data
    ) throws -> Data {
        guard !viewport.isEmpty else { return data }
        // Only appState changes; splice it instead of re-encoding every element.
        if let member = TopLevelJSONMember.locate("appState", in: data) {
            var appStateObject: [String: Any] = [:]
            if case .found(let valueRange, _) = member {
                appStateObject = try JSONSerialization.jsonObject(
                    with: data.subdata(in: valueRange),
                    options: .fragmentsAllowed
                ) as? [String: Any] ?? [:]
            }
            for key in strippedViewportKeys {
                appStateObject.removeValue(forKey: key)
            }
            for (key, value) in viewport.values {
                appStateObject[key] = value.foundationObject
            }
            return try member.replacingValue(
                in: data,
                with: JSONSerialization.data(withJSONObject: appStateObject),
                key: "appState"
            )
        }
        guard
              var contentObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }

        var appStateObject = contentObject["appState"] as? [String: Any] ?? [:]
        for key in strippedViewportKeys {
            appStateObject.removeValue(forKey: key)
        }
        for (key, value) in viewport.values {
            appStateObject[key] = value.foundationObject
        }
        contentObject["appState"] = appStateObject
        return try JSONSerialization.data(withJSONObject: contentObject)
    }

    private static func contentDataByRemovingViewport(from data: Data) throws -> Data {
        if let member = TopLevelJSONMember.locate("appState", in: data) {
            guard case .found(let valueRange, _) = member,
                  var appState = try JSONSerialization.jsonObject(
                    with: data.subdata(in: valueRange),
                    options: .fragmentsAllowed
                  ) as? [String: Any],
                  strippedViewportKeys.contains(where: { appState[$0] != nil }) else {
                return data
            }
            for key in strippedViewportKeys {
                appState.removeValue(forKey: key)
            }
            return try member.replacingValue(
                in: data,
                with: JSONSerialization.data(withJSONObject: appState),
                key: "appState"
            )
        }
        guard var contentObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }

        guard let appStateObject = contentObject["appState"] else {
            return data
        }

        contentObject["appState"] = appStateObjectByRemovingViewport(from: appStateObject)
        return try JSONSerialization.data(withJSONObject: contentObject)
    }

    private static func appStateObjectByRemovingViewport(from appStateObject: Any) -> Any {
        guard var appState = appStateObject as? [String: Any] else {
            return appStateObject
        }

        for key in strippedViewportKeys {
            appState.removeValue(forKey: key)
        }
        return appState
    }

    private static func jsonValue(from object: Any) throws -> ExcalidrawCore.JSONValue {
        let data = try JSONSerialization.data(withJSONObject: ["value": object])
        return try JSONDecoder().decode(JSONValueWrapper.self, from: data).value
    }
}

/// Finds one member of a JSON document's top-level object without building
/// the rest of the document. Large scenes are mostly `elements` and `files`;
/// viewport handling only needs the small `appState` member.
///
/// `locate` returns nil whenever the bytes are not a plain top-level object
/// it can walk safely (escaped keys, duplicate target keys, trailing bytes),
/// and callers then use the full Foundation parse.
enum TopLevelJSONMember {
    /// The value's byte range and the whole `"key": value` member range.
    case found(value: Range<Int>, member: Range<Int>)
    /// The key is absent. `closingBrace` is the object's final `}`.
    case absent(closingBrace: Int, isEmpty: Bool)

    static func locate(_ key: String, in data: Data) -> TopLevelJSONMember? {
        let target = Array(key.utf8)
        return data.withUnsafeBytes { raw -> TopLevelJSONMember? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var scanner = Scanner(bytes: bytes)
            scanner.skipWhitespace()
            guard scanner.consume(UInt8(ascii: "{")) else { return nil }
            var found: TopLevelJSONMember?
            var memberCount = 0
            while true {
                scanner.skipWhitespace()
                if scanner.peek == UInt8(ascii: "}") {
                    guard memberCount == 0 else { return nil }
                    break
                }
                let memberStart = scanner.index
                guard let keyRange = scanner.skipString(),
                      !bytes[keyRange].contains(UInt8(ascii: "\\")) else { return nil }
                scanner.skipWhitespace()
                guard scanner.consume(UInt8(ascii: ":")) else { return nil }
                scanner.skipWhitespace()
                let valueStart = scanner.index
                guard scanner.skipValue() else { return nil }
                let valueEnd = scanner.index
                memberCount += 1
                if bytes[keyRange].elementsEqual(target) {
                    guard found == nil else { return nil }
                    found = .found(value: valueStart..<valueEnd, member: memberStart..<valueEnd)
                }
                scanner.skipWhitespace()
                if scanner.consume(UInt8(ascii: ",")) { continue }
                guard scanner.peek == UInt8(ascii: "}") else { return nil }
                break
            }
            let closingBrace = scanner.index
            scanner.index += 1
            scanner.skipWhitespace()
            guard scanner.isAtEnd else { return nil }
            return found ?? .absent(closingBrace: closingBrace, isEmpty: memberCount == 0)
        }.map { $0.offset(by: data.startIndex) }
    }

    /// The value bytes, for callers that only read the member.
    func value(in data: Data) -> Data? {
        guard case .found(let valueRange, _) = self else { return nil }
        return data.subdata(in: valueRange)
    }

    private func offset(by base: Int) -> TopLevelJSONMember {
        switch self {
            case .found(let value, let member):
                return .found(
                    value: (value.lowerBound + base)..<(value.upperBound + base),
                    member: (member.lowerBound + base)..<(member.upperBound + base)
                )
            case .absent(let closingBrace, let isEmpty):
                return .absent(closingBrace: closingBrace + base, isEmpty: isEmpty)
        }
    }

    /// Replaces the member's value, or appends `"key": value` when absent.
    func replacingValue(in data: Data, with value: Data, key: String) throws -> Data {
        var result = Data()
        switch self {
            case .found(let valueRange, _):
                result.reserveCapacity(data.count - valueRange.count + value.count)
                result.append(data.subdata(in: data.startIndex..<valueRange.lowerBound))
                result.append(value)
                result.append(data.subdata(in: valueRange.upperBound..<data.endIndex))
            case .absent(let closingBrace, let isEmpty):
                let keyData = try JSONSerialization.data(withJSONObject: key, options: .fragmentsAllowed)
                result.reserveCapacity(data.count + keyData.count + value.count + 2)
                result.append(data.subdata(in: data.startIndex..<closingBrace))
                if !isEmpty { result.append(UInt8(ascii: ",")) }
                result.append(keyData)
                result.append(UInt8(ascii: ":"))
                result.append(value)
                result.append(data.subdata(in: closingBrace..<data.endIndex))
        }
        return result
    }

    private struct Scanner {
        let bytes: UnsafeBufferPointer<UInt8>
        var index = 0

        var isAtEnd: Bool { index >= bytes.count }
        var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard peek == byte else { return false }
            index += 1
            return true
        }

        mutating func skipWhitespace() {
            while let byte = peek,
                  byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 {
                index += 1
            }
        }

        /// Skips a string and returns the range of its raw contents.
        mutating func skipString() -> Range<Int>? {
            guard consume(UInt8(ascii: "\"")) else { return nil }
            let start = index
            while index < bytes.count {
                switch bytes[index] {
                    case UInt8(ascii: "\\"):
                        index += 2
                    case UInt8(ascii: "\""):
                        let end = index
                        index += 1
                        return start..<end
                    default:
                        index += 1
                }
            }
            return nil
        }

        mutating func skipValue() -> Bool {
            guard let byte = peek else { return false }
            switch byte {
                case UInt8(ascii: "\""):
                    return skipString() != nil
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    var depth = 0
                    while let current = peek {
                        switch current {
                            case UInt8(ascii: "\""):
                                guard skipString() != nil else { return false }
                                continue
                            case UInt8(ascii: "{"), UInt8(ascii: "["):
                                depth += 1
                            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                                depth -= 1
                                if depth == 0 {
                                    index += 1
                                    return true
                                }
                            default:
                                break
                        }
                        index += 1
                    }
                    return false
                default:
                    let start = index
                    while let current = peek,
                          current != UInt8(ascii: ","),
                          current != UInt8(ascii: "}"),
                          current != UInt8(ascii: "]"),
                          current != 0x20, current != 0x0A, current != 0x0D, current != 0x09 {
                        index += 1
                    }
                    return index > start
            }
        }
    }
}
