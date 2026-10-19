//
//  ExcalidrawServer.swift
//  ExcalidrawZ
//
//  Created by Dove Zachary on 2024/8/9.
//

import Foundation
import FlyingFox
import FlyingSocks

import ChocofordUI

struct ExcalidrawServerLogger: Logging {
    func logDebug(_ debug: @autoclosure () -> String) {
            
    }
    
    func logInfo(_ info: @autoclosure () -> String) {
        
    }
    
    func logWarning(_ warning: @autoclosure () -> String) {
        
    }
    
    func logError(_ error: @autoclosure () -> String) {
        
    }
    
    func logCritical(_ critical: @autoclosure () -> String) {
        
    }
}

class ExcalidrawServer {
    static var port: UInt16 {
        // An installed app can remain open while XCTest serves its own bundled
        // editor. Never let tests silently exercise an older app's assets.
        if AppRuntime.isRunningTests { return 18497 }
        if ExcalidrawFeaturePolicy.isLocalMacOSFork { return 8497 }
#if DEBUG
        return 8486
#else
        return 8487
#endif
    }
    static var editorURL: URL {
        URL(string: "http://127.0.0.1:\(port)/index.html")!
    }
    let server = HTTPServer(
        address: try! .inet(ip4: "127.0.0.1", port: ExcalidrawServer.port),
        logger: ExcalidrawServerLogger()
    )
    init(autoStart: Bool = true) {
        if isPreview { return }
        if autoStart {
            Task {
                try? await self.start()
            }
        }
    }
    
    deinit {
        let server = self.server
        Task {
            await server.stop()
        }
    }
    
    func start() async throws {
        await server.appendRoute(
            "GET /*",
            to: ContainedDirectoryHTTPHandler(
                root: Bundle.main.resourceURL?.appendingPathComponent("excalidraw-latest", isDirectory: true),
                inner: DirectoryHTTPHandler(
                    bundle: .main,
                    subPath: "excalidraw-latest",
                    serverPath: ""
                )
            )
        )
        try await server.run()
    }
    
    
    func stop() async {
        await server.stop()
    }
}

/// Serves only files inside the bundled editor directory. The library handler
/// decodes `%2e%2e` segments without containing them, which exposed any file the
/// user can read to every local process through the loopback port.
struct ContainedDirectoryHTTPHandler: HTTPHandler {
    let root: URL?
    let inner: any HTTPHandler

    func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let root, Self.isContained(requestPath: request.path, in: root) else {
            return HTTPResponse(statusCode: .notFound)
        }
        return try await inner.handleRequest(request)
    }

    static func isContained(requestPath: String, in root: URL) -> Bool {
        let decoded = requestPath.removingPercentEncoding ?? requestPath
        guard !decoded.contains("\0") else { return false }
        let components = decoded.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(where: { $0 == ".." || $0 == "." }) else { return false }
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = components.reduce(root) { $0.appendingPathComponent(String($1)) }
            .standardizedFileURL.resolvingSymlinksInPath().path
        return candidate == resolvedRoot || candidate.hasPrefix(resolvedRoot + "/")
    }
}
