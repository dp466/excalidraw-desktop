//
//  ExcalidrawFile.swift
//  ExcalidrawZ
//
//  Created by Dove Zachary on 2024/7/25.
//

import SwiftUI
import UniformTypeIdentifiers

import CoreData


struct ExcalidrawFile: Codable, Hashable, Identifiable, Sendable {
    /// Stable editor IDs for linked local files. Read and written from the main
    /// actor and from background folder refresh, cover rendering and imports,
    /// so all access goes through a lock.
    private static let localFileIDLock = NSLock()
    private static var localFileIDStorage: [URL: String] = [:]

    private static func withLocalFileIDs<T>(_ body: (inout [URL: String]) -> T) -> T {
        localFileIDLock.lock()
        defer { localFileIDLock.unlock() }
        return body(&localFileIDStorage)
    }

    static var localFileURLIDMapping: [URL: String] {
        get { withLocalFileIDs { $0 } }
        set { withLocalFileIDs { $0 = newValue } }
    }

    /// Returns the existing ID for `url`, or records and returns a new one, atomically.
    static func localFileID(for url: URL, refresh: Bool = false) -> String {
        withLocalFileIDs { storage in
            if !refresh, let id = storage[url] { return id }
            let id = UUID().uuidString
            storage[url] = id
            return id
        }
    }

    /// Moves an ID to a renamed or moved file, atomically, and remembers the
    /// move so a save still bound to the old path can follow the file.
    static func moveLocalFileID(from source: URL, to destination: URL) {
        withLocalFileIDs { storage in
            // Enumerators may return /private/var for a file registered as /var.
            // The source no longer exists here, so compare paths without disk access.
            let key = storage[source] != nil ? source : storage.keys.first {
                comparablePath($0) == comparablePath(source)
            }
            if let key, let id = storage.removeValue(forKey: key) {
                storage[destination] = id
            }
        }
        localFileMoveLock.lock()
        defer { localFileMoveLock.unlock() }
        recentLocalFileMoves[source.standardizedFileURL] = destination.standardizedFileURL
        recentLocalFileMoveOrder.append(source.standardizedFileURL)
        if recentLocalFileMoveOrder.count > 128 {
            recentLocalFileMoves[recentLocalFileMoveOrder.removeFirst()] = nil
        }
    }

    private static func comparablePath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }

    private static let localFileMoveLock = NSLock()
    private static var recentLocalFileMoves: [URL: URL] = [:]
    private static var recentLocalFileMoveOrder: [URL] = []

    /// Where an in-app move took a file that was at `url`, following chained moves.
    static func currentLocation(ofMoved url: URL) -> URL? {
        localFileMoveLock.lock()
        defer { localFileMoveLock.unlock() }
        var current = url.standardizedFileURL
        var visited: Set<URL> = []
        while let next = recentLocalFileMoves[current], visited.insert(current).inserted {
            current = next
        }
        return current == url.standardizedFileURL ? nil : current
    }
    
    var id: String = UUID().uuidString
    
    var source: String
    var files: [String: ResourceFile]
    var version: Int
    var elements: [ExcalidrawElement]
    var appState: AppState
    var type: String
    
    // MARK: Additional info (would not be encoded)
    /// The file content encoded to data.
    var content: Data?
    var name: String?
    
    // Collab
    var roomID: String?
    
    struct AppState: Codable, Hashable, Sendable {
        var gridSize: Int?
        var viewBackgroundColor: String?
    }
    struct ResourceFile: Codable, Hashable, Sendable {
        var mimeType: String
        var id: String
        var createdAt: Date?
        var dataURL: String
        var lastRetrievedAt: Date?
        
        enum CodingKeys: String, CodingKey {
            case mimeType
            case id
            case createdAt = "created"
            case dataURL
            case lastRetrievedAt = "lastRetrieved"
        }
        
        init(
            mimeType: String,
            id: String,
            createdAt: Date? = nil,
            dataURL: String,
            lastRetrievedAt: Date? = nil
        ) {
            self.mimeType = mimeType
            self.id = id
            self.createdAt = createdAt
            self.dataURL = dataURL
            self.lastRetrievedAt = lastRetrievedAt
        }
        
        init(from decoder: any Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            self.mimeType = try container.decode(String.self, forKey: ExcalidrawFile.ResourceFile.CodingKeys.mimeType)
            self.id = try container.decode(String.self, forKey: .id)
            // Timestamps are milliseconds; other tools write them with a
            // fraction, which an Int decode rejected along with the drawing.
            if let created = try container.decodeIfPresent(Double.self, forKey: .createdAt) {
                self.createdAt = Date(timeIntervalSince1970: created / 1000)
            }
            self.dataURL = try container.decode(String.self, forKey: .dataURL)
            if let lastRetrieved = try container.decodeIfPresent(Double.self, forKey: .lastRetrievedAt) {
                let lastRetrievedAt = Date(timeIntervalSince1970: lastRetrieved / 1000)
                self.lastRetrievedAt = lastRetrievedAt
                if lastRetrievedAt.timeIntervalSinceNow > 0 {
                    self.lastRetrievedAt = Date(
                        timeIntervalSince1970: lastRetrievedAt.timeIntervalSince1970 / 1000
                    )
                }
            }
        }
        
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.mimeType, forKey: .mimeType)
            try container.encode(self.id, forKey: .id)
            if let createdAt = self.createdAt {
                try container.encode(
                    Int(createdAt.timeIntervalSince1970 * 1000),
                    forKey: .createdAt
                )
            }
            try container.encode(self.dataURL, forKey: .dataURL)
            if let lastRetrievedAt = self.lastRetrievedAt {
                try container.encode(
                    Int(lastRetrievedAt.timeIntervalSince1970 * 1000),
                    forKey: .lastRetrievedAt
                )
            }
        }
    }
    
    init(
        id: String = UUID().uuidString,
        source: String,
        files: [String : ResourceFile],
        version: Int,
        elements: [ExcalidrawElement],
        appState: AppState,
        type: String
    ) {
        self.id = id
        self.source = source
        self.files = files
        self.version = version
        self.elements = elements
        self.appState = appState
        self.type = type
    }
    
    enum CodingKeys: String, CodingKey {
        case source
        case files
        case version
        case elements
        case appState
        case type
        // case roomID
    }
    
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.source = try container.decodeIfPresent(String.self, forKey: .source) ?? "https://excalidraw.com"
        // maybe empty if from core data
        self.files = try container.decodeIfPresent([String : ExcalidrawFile.ResourceFile].self, forKey: .files) ?? [:]
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 2
        self.elements = try container.decodeIfPresent([ExcalidrawElement].self, forKey: .elements) ?? []
        self.appState = try container.decodeIfPresent(ExcalidrawFile.AppState.self, forKey: .appState) ?? .init()
        self.type = try container.decode(String.self, forKey: .type)
    }
    
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.source, forKey: .source)
        try container.encode(self.files, forKey: .files)
        try container.encode(self.version, forKey: .version)
        try container.encode(self.elements, forKey: .elements)
        try container.encode(self.appState, forKey: .appState)
        try container.encode(self.type, forKey: .type)
        // try container.encode(self.roomID, forKey: .roomID)
    }
    
    /// Decoded once: callers create blank files often (boundary saves, new files).
    private static let template: ExcalidrawFile = {
        try! ExcalidrawFile(contentsOf: Bundle.main.url(forResource: "template", withExtension: "excalidraw")!)
    }()

    init() {
        self = Self.template
    }
    
    init(contentsOf url: URL, refresh: Bool = false) throws {
        let fileType: UTType = {
            let lastPathComponent = url.lastPathComponent
            
            if lastPathComponent.hasSuffix(".excalidraw.png") {
                return .excalidrawPNG
            } else if lastPathComponent.hasSuffix(".excalidraw.svg") {
                return .excalidrawSVG
            } else {
                return UTType(filenameExtension: url.pathExtension) ?? .excalidrawFile
            }
        }()
        let data: Data
        switch fileType {
            case .excalidrawFile:
                // .uncached fixes the import bug occurs in x86 mac OS
                data = try Data(contentsOf: url, options: .uncached)
            case .excalidrawPNG:
                // .uncached fixes the import bug occurs in x86 mac OS
                let fileData = try Data(contentsOf: url, options: .uncached)
                if let excalidrawFile = ExcalidrawPNGDecoder().decode(from: fileData) {
                    data = try JSONEncoder().encode(excalidrawFile)
                } else {
                    data = try Data(contentsOf: url, options: .uncached)
                }
            case .excalidrawSVG:
                // .uncached fixes the import bug occurs in x86 mac OS
                let fileData = try Data(contentsOf: url, options: .uncached)
                if let excalidrawFile = ExcalidrawSVGDecoder().decode(from: fileData) {
                    data = try JSONEncoder().encode(excalidrawFile)
                } else {
                    data = try Data(contentsOf: url, options: .uncached)
                }
            default:
                struct UnrecognizedURLError: Error {}
                throw UnrecognizedURLError()
        }
        let id = Self.localFileID(for: url, refresh: refresh)
        try self.init(data: data, id: id)
        switch fileType {
            case .excalidrawFile:
                self.name = url.deletingPathExtension().lastPathComponent
            case .excalidrawPNG, .excalidrawSVG:
                let lastPathComponent = url.deletingPathExtension().lastPathComponent
                if let index = lastPathComponent.lastIndex(of: ".") {
                    self.name = String(lastPathComponent.prefix(upTo: index))
                } else {
                    self.name = lastPathComponent
                }
            default:
                break
        }
    }
    
    init(data: Data, id: String? = nil) throws {
        self = try JSONDecoder().decode(ExcalidrawFile.self, from: data)
        self.content = data
        if let id {
            self.id = id
        }
    }

    /// JSON parsing can be substantial for image-heavy drawings. Keep it off
    /// the UI actor; the caller still validates the active file before publishing.
    static func decodeForOpening(data: Data, id: String) async throws -> ExcalidrawFile {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let file = try ExcalidrawFile(data: data, id: id)
            try Task.checkCancellation()
            return file
        }
        return try await withTaskCancellationHandler {
            let file = try await task.value
            try Task.checkCancellation()
            return file
        } onCancel: {
            task.cancel()
        }
    }
    
    func contentWithoutFiles() throws -> Data {
        guard let content,
              var jsonObj = try JSONSerialization.jsonObject(with: content) as? [String : Any] else {
            struct UnexpectedContentData: Error {}
            throw UnexpectedContentData()
        }
        jsonObj.removeValue(forKey: "files")
        return try JSONSerialization.data(withJSONObject: jsonObj)
    }
}


extension UTType {
    static var excalidrawFile: UTType {
        UTType(importedAs: "com.chocoford.excalidrawFile", conformingTo: .json)
    }
    static var excalidrawlibFile: UTType {
        UTType(importedAs: "com.chocoford.excalidrawlibFile", conformingTo: .json)
    }
    static var excalidrawlibJSON: UTType {
        UTType(exportedAs: "com.chocoford.excalidrawlibJSON", conformingTo: .json)
    }
    static var excalidrawPNG: UTType {
        UTType(exportedAs: "com.chocoford.excalidrawPNG", conformingTo: .png)
    }
    static var excalidrawSVG: UTType {
        UTType(exportedAs: "com.chocoford.excalidrawSVG", conformingTo: .svg)
    }
}


#if DEBUG
extension ExcalidrawFile {
    static let preview: ExcalidrawFile = {
        ExcalidrawFile()
    }()
}


#endif
