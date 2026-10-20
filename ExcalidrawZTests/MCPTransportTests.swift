import Foundation
import Testing
import XCTest
import Security
import FlyingFox
import FlyingSocks
@testable import ExcalidrawZ

#if os(macOS)
/// Uses a fresh service namespace; never reads or modifies production clients.
final class MCPKeychainCredentialTests: XCTestCase {
    func testIsolatedKeychainCredentialPersistsAuthenticatesAndRevokes() throws {
        let store = ExcalidrawMCPCredentialStore(bundleIdentifier: "mcp-test-" + UUID().uuidString)
        var createdID: UUID?
        defer { if let createdID { try? store.revoke(id: createdID) } }
        do {
            let summary = try store.createClient(kind: .codex)
            createdID = summary.id
            let credential = try XCTUnwrap(store.credential(id: summary.id))
            XCTAssertTrue(credential.id == summary.id)
            XCTAssertTrue(credential.kind == .codex)
            XCTAssertTrue(credential.token.hasPrefix("exz_"))
            // Boolean assertions avoid printing a token if a regression fails.
            XCTAssertTrue(try store.authenticate(authorization: "Bearer " + credential.token) == summary.id.uuidString)
            XCTAssertNil(try store.authenticate(authorization: "Bearer " + credential.token + "invalid"))
            XCTAssertNil(try store.authenticate(authorization: nil))
            let summaries = try store.listClients()
            XCTAssertTrue(summaries.count == 1 && summaries[0].id == summary.id)
            // Listing reads the non-secret kind label, not the encrypted token.
            XCTAssertTrue(summaries.first?.kind == .codex)
            try store.revoke(id: summary.id)
            XCTAssertTrue(try store.credential(id: summary.id).map { _ in false } ?? true)
            XCTAssertNil(try store.authenticate(authorization: "Bearer " + credential.token))
            XCTAssertTrue(try store.listClients().isEmpty)
        } catch let failure as ExcalidrawMCPCredentialStore.KeychainFailure {
            if [errSecInteractionNotAllowed, errSecInteractionRequired].contains(failure.status) {
                throw XCTSkip("Isolated credential test needs an unlocked Keychain; Security status \(failure.status).")
            }
            XCTFail("Isolated login Keychain credential regression failed during \(failure.operation); Security status \(failure.status).")
            throw failure
        }
    }
}
#endif

struct MCPTransportTests {
    private let port: UInt16 = 8490
    private let metadata: MCPJSONValue = .object([
        "io.modelcontextprotocol/protocolVersion": .string("2026-07-28"),
        "io.modelcontextprotocol/clientCapabilities": .object([:])
    ])
    private func rpc(method: String = "tools/list", params: [String: MCPJSONValue] = [:], modern: Bool = true, id: MCPJSONValue? = .number(1)) -> MCPJSONRPCRequest {
        var params = params
        if modern { params["_meta"] = metadata }
        return MCPJSONRPCRequest(jsonrpc: "2.0", id: id, method: method, params: .object(params))
    }
    private func headers(method: String = "tools/list") -> [String: String] {
        ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": method]
    }
    private func handler(execute: (@Sendable (MCPJSONRPCRequest, MCPRequestContext) async -> MCPJSONRPCResponse?)? = nil) -> ExcalidrawMCPHTTPHandler {
        ExcalidrawMCPHTTPHandler(port: port, router: .init(serviceMode: .basic), requests: .init(), authenticate: { $0 == "Bearer test" ? "test-client" : nil }, execute: execute)
    }
    private func http(_ request: MCPJSONRPCRequest, extraHeaders: [HTTPHeader: String] = [:]) throws -> HTTPRequest {
        var headers: [HTTPHeader: String] = [.host: "127.0.0.1:\(port)", .authorization: "Bearer test", .contentType: "application/json", HTTPHeader("Accept"): "application/json, text/event-stream"]
        if request.metadata["io.modelcontextprotocol/protocolVersion"] != nil {
            headers[HTTPHeader("MCP-Protocol-Version")] = "2026-07-28"
            headers[HTTPHeader("Mcp-Method")] = request.method
            if let name = request.params?["name"]?.stringValue { headers[HTTPHeader("Mcp-Name")] = name }
        }
        headers.merge(extraHeaders) { _, new in new }
        var value: [String: MCPJSONValue] = ["jsonrpc": .string("2.0"), "method": .string(request.method)]
        value["id"] = request.id; value["params"] = request.params
        return HTTPRequest(method: .POST, version: .http11, path: "/mcp", query: [], headers: headers, body: try MCPJSONValue.object(value).mcpJSONData())
    }

    @Test func modernRequestsAreIndependentAndValidateMirroredHeaders() throws {
        #expect(try MCPTransportPolicy.validate(rpc(), headers: headers()) == "2026-07-28")
        do {
            _ = try MCPTransportPolicy.validate(rpc(), headers: headers(method: "tools/call"))
            Issue.record("Mismatched method accepted")
        } catch let error as MCPJSONRPCError { #expect(error.code == -32020) }
        do {
            _ = try MCPTransportPolicy.validate(rpc(), headers: ["Mcp-Method": "tools/list"])
            Issue.record("Missing protocol header accepted")
        } catch let error as MCPJSONRPCError { #expect(error.code == -32020) }
    }

    @Test func acceptHeaderRequiresBothExactUsableResponseTypes() async throws {
        #expect(MCPTransportPolicy.acceptsResponseTypes("Application/JSON; q=0.5, text/event-stream; q=1"))
        for value in [nil, "application/json", "application/json-fake,text/event-stream", "application/json,text/event-stream-fake", "application/json;q=0,text/event-stream", "application/json,text/event-stream; q = 0", "application/json,text/event-stream;q=invalid", "application/json,text/event-stream;q=0.5;q=1"] as [String?] {
            #expect(!MCPTransportPolicy.acceptsResponseTypes(value))
        }
        let response = try await handler().handleRequest(http(rpc(), extraHeaders: [HTTPHeader("Accept"): "application/json, text/event-stream;q=0"]))
        #expect(response.statusCode == .notAcceptable)
    }

    @Test func modernMetadataIsRequiredAndUnknownVersionsAreReported() throws {
        do {
            _ = try MCPTransportPolicy.validate(rpc(modern: false), headers: headers())
            Issue.record("Missing metadata accepted")
        } catch let error as MCPJSONRPCError { #expect(error.code == -32602) }
        do {
            _ = try MCPTransportPolicy.validate(rpc(), headers: ["MCP-Protocol-Version": "2099-01-01"])
            Issue.record("Unsupported version accepted")
        } catch let error as MCPJSONRPCError {
            #expect(error.code == -32022)
            #expect(error.data?["supported"]?.arrayValue?.contains(.string("2026-07-28")) == true)
        }
    }

    @Test func legacyInitializeNegotiatesEachSupportedVersion() throws {
        for version in MCPTransportPolicy.legacyVersions + ["2024-11-05"] {
            let request = rpc(method: "initialize", params: ["protocolVersion": .string(version), "capabilities": .object([:]), "clientInfo": .object(["name": .string("test"), "version": .string("1")])], modern: false)
            #expect(try MCPTransportPolicy.validate(request, headers: [:]) == (version == "2024-11-05" ? "2025-11-25" : version))
        }
    }

    @Test func concurrentLegacyInitializationsSharingCredentialDoNotReplaceRequestVersions() async throws {
        let router = ExcalidrawMCPToolRouter(serviceMode: .basic)
        let serverHandler = handler(execute: { request, context in
            if request.method == "tools/call" {
                return .success(id: request.id, result: .object(["served_version": .string(context.protocolVersion)]))
            }
            return await router.handle(request, context: context)
        })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for version in MCPTransportPolicy.legacyVersions {
                group.addTask {
                    let initialize = rpc(method: "initialize", params: ["protocolVersion": .string(version), "capabilities": .object([:]), "clientInfo": .object(["name": .string("test"), "version": .string("1")])], modern: false)
                    let response = try await serverHandler.handleRequest(http(initialize))
                    let body = try await MCPJSONValue.parse(from: response.bodyData)
                    #expect(body["result"]?["protocolVersion"] == .string(version))
                }
            }
            while try await group.next() != nil {}
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, version) in MCPTransportPolicy.legacyVersions.enumerated() {
                group.addTask {
                    let versionHeader: [HTTPHeader: String] = [HTTPHeader("MCP-Protocol-Version"): version]
                    let listed = try await serverHandler.handleRequest(http(rpc(modern: false), extraHeaders: versionHeader))
                    let list = try await MCPJSONValue.parse(from: listed.bodyData)
                    #expect(listed.statusCode == .ok)
                    #expect(list["error"] == nil)
                    #expect(list["result"]?["tools"]?.arrayValue != nil)
                    let called = try await serverHandler.handleRequest(http(rpc(method: "tools/call", params: ["name": .string("test")], modern: false, id: .number(Double(100 + index))), extraHeaders: versionHeader))
                    let events = String(decoding: try await called.bodyData, as: UTF8.self)
                    let event = try #require(events.components(separatedBy: "\n").first { $0.hasPrefix("data: ") })
                    let result = try MCPJSONValue.parse(from: Data(event.dropFirst(6).utf8))
                    #expect(result["result"]?["served_version"] == .string(version))
                }
            }
            while try await group.next() != nil {}
        }
        // No credential-wide fallback remains after those initializations.
        #expect(try MCPTransportPolicy.validate(rpc(modern: false), headers: [:]) == "2025-03-26")
    }

    @Test func unsupportedLegacyHeadersAndMixedModernVersionsRemainRejected() async throws {
        for version in ["", "invalid", "2024-11-05", "2099-01-01"] {
            let response = try await handler().handleRequest(http(rpc(modern: false), extraHeaders: [HTTPHeader("MCP-Protocol-Version"): version]))
            #expect(response.statusCode == .badRequest)
            let body = try await MCPJSONValue.parse(from: response.bodyData)
            #expect(body["error"]?["code"] == .number(-32022))
        }
        let mixed = try await handler().handleRequest(http(rpc(), extraHeaders: [HTTPHeader("MCP-Protocol-Version"): "2025-11-25"]))
        #expect(mixed.statusCode == .badRequest)
        #expect(try await MCPJSONValue.parse(from: mixed.bodyData)["error"]?["code"] == .number(-32020))
    }

    @Test func encodedNamesAreDecodedBeforeComparison() throws {
        let name = "diagram 世界"
        var headers = headers(method: "tools/call")
        headers["Mcp-Name"] = "=?base64?\(Data(name.utf8).base64EncodedString())?="
        #expect(try MCPTransportPolicy.validate(rpc(method: "tools/call", params: ["name": .string(name)]), headers: headers) == "2026-07-28")
        #expect(throws: MCPJSONRPCError.self) { try MCPTransportPolicy.decodeHeaderValue("=?base64?invalid?=") }
    }

    @Test func jsonRPCRequiresVersionAndScalarIDsAndEncodesNullErrorID() throws {
        #expect(throws: MCPJSONRPCError.self) { try MCPJSONRPCRequest(jsonrpc: nil, id: .number(1), method: "tools/list", params: nil).validate() }
        #expect(throws: MCPJSONRPCError.self) { try rpc(id: .bool(true)).validate() }
        #expect(throws: MCPJSONRPCError.self) { try rpc(id: .null).validate() }
        let nullID = try JSONDecoder().decode(MCPJSONRPCRequest.self, from: Data("{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"notifications/initialized\"}".utf8))
        #expect(throws: MCPJSONRPCError.self) { try nullID.validate() }
        let response = try MCPJSONValue.parse(from: MCPJSONRPCResponse.failure(id: nil, error: .parseError("invalid")).mcpJSONData())
        #expect(response["id"] == .null)
        #expect(response["result"] == nil)
    }

    @Test func localEndpointRejectsOtherHostsAndOrigins() {
        #expect(MCPTransportPolicy.allowsHost("localhost:8490", port: port))
        #expect(MCPTransportPolicy.allowsHost("127.0.0.1:8490", port: port))
        #expect(!MCPTransportPolicy.allowsHost("evil.example:8490", port: port))
        #expect(!MCPTransportPolicy.allowsHost("127.0.0.1:8491", port: port))
        #expect(MCPTransportPolicy.allowsOrigin(nil, port: port))
        #expect(!MCPTransportPolicy.allowsOrigin("null", port: port))
        #expect(!MCPTransportPolicy.allowsOrigin("https://evil.example", port: port))
    }

    @Test func discoveryHasOnlyImplementedCapabilitiesAndModernResultShape() async throws {
        let response = try await handler().handleRequest(http(rpc(method: "server/discover")))
        #expect(response.statusCode == .ok)
        let body = try await MCPJSONValue.parse(from: response.bodyData)
        #expect(body["result"]?["resultType"] == .string("complete"))
        #expect(body["result"]?["ttlMs"] == .number(0))
        #expect(body["result"]?["cacheScope"] == .string("private"))
        #expect(body["result"]?["capabilities"] == .object(["tools": .object([:])]))
        #expect(body["result"]?["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"] == .string("ExcalidrawDesktop"))
    }

    @Test func modernSuccessfulResponsesHaveCompletePrivateZeroTTLEnvelopes() async throws {
        let router = ExcalidrawMCPToolRouter(serviceMode: .full)
        let context = MCPRequestContext(clientID: "transport-test", protocolVersion: "2026-07-28")
        for request in [rpc(method: "server/discover"), rpc(), rpc(method: "tools/call", params: ["name": .string("read_me"), "arguments": .object([:])])] {
            let response = try #require(await router.handle(request, context: context))
            #expect(response.error == nil)
            let result = try #require(response.result)
            #expect(result["resultType"] == .string("complete"))
            #expect(result["ttlMs"] == .number(0))
            #expect(result["cacheScope"] == .string("private"))
            #expect(result["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"] == .string("ExcalidrawDesktop"))
            if request.method == "tools/call" { #expect(result["content"]?.arrayValue?.isEmpty == false) }
        }
    }

    @Test func legacyResultsKeepTheirInitializationBasedShape() async throws {
        let router = ExcalidrawMCPToolRouter(serviceMode: .full)
        let context = MCPRequestContext(clientID: "transport-test", protocolVersion: "2025-11-25")
        let initialize = rpc(method: "initialize", params: ["protocolVersion": .string("2025-11-25"), "capabilities": .object([:]), "clientInfo": .object(["name": .string("test"), "version": .string("1")])], modern: false)
        for request in [initialize, rpc(modern: false), rpc(method: "tools/call", params: ["name": .string("read_me"), "arguments": .object([:])], modern: false)] {
            let response = try #require(await router.handle(request, context: context))
            #expect(response.error == nil)
            let result = try #require(response.result)
            #expect(result["resultType"] == nil)
            #expect(result["ttlMs"] == nil)
            #expect(result["cacheScope"] == nil)
        }
    }

    @Test func methodErrorsHaveModernHTTP404AndHealthIsSanitized() async throws {
        let handler = handler()
        let response = try await handler.handleRequest(http(rpc(method: "missing_method")))
        #expect(response.statusCode == .notFound)
        let get = HTTPRequest(method: .GET, version: .http11, path: "/mcp", query: [], headers: [.host: "127.0.0.1:8490"], body: Data())
        #expect(try await handler.handleRequest(get).statusCode == .methodNotAllowed)
        let health = HTTPRequest(method: .GET, version: .http11, path: "/health", query: [], headers: [.host: "127.0.0.1:8490"], body: Data())
        #expect(try await handler.handleRequest(health).bodyData == Data("{\"status\":\"ok\"}".utf8))
    }

    @Test func unauthorizedAndInvalidOriginCallsNeverExecute() async throws {
        let handler = handler(execute: { _, _ in Issue.record("Rejected request executed"); return nil })
        #expect(try await handler.handleRequest(http(rpc(), extraHeaders: [.authorization: "Bearer revoked"])).statusCode == .unauthorized)
        #expect(try await handler.handleRequest(http(rpc(), extraHeaders: [HTTPHeader("Origin"): "https://evil.example"])).statusCode == .forbidden)
    }

    @Test func legacyNotificationsReturn202WithEmptyBody() async throws {
        let handler = handler()
        let initialize = rpc(method: "initialize", params: ["protocolVersion": .string("2025-11-25"), "capabilities": .object([:]), "clientInfo": .object(["name": .string("test"), "version": .string("1")])], modern: false)
        _ = try await handler.handleRequest(http(initialize))
        let response = try await handler.handleRequest(http(rpc(method: "notifications/initialized", modern: false, id: nil)))
        #expect(response.statusCode == .accepted)
        #expect(try await response.bodyData.isEmpty)
    }

    @Test func atomicOperationSchemaRejectsInvalidUnionAndUnknownFields() throws {
        let schema = try #require(ExcalidrawMCPFullToolCatalog.tools.first(where: { $0.name == "apply_operations" })?.inputSchema)
        let base: [String: MCPJSONValue] = ["document_id": .string("test"), "expected_revision": .string("r"), "request_id": .string("q")]
        let good = base.merging(["operations": .array([.object(["type": .string("move"), "ids": .array([.string("node")]), "dx": .number(5)])])]) { _, v in v }
        try MCPJSONSchemaValidator.validate(.object(good), schema: schema)
        var bad = good; bad["operations"] = .array([.object(["type": .string("move"), "ids": .string("node")])])
        #expect(throws: MCPJSONRPCError.self) { try MCPJSONSchemaValidator.validate(.object(bad), schema: schema) }
        bad = good; bad["secret_extra"] = .bool(true)
        #expect(throws: MCPJSONRPCError.self) { try MCPJSONSchemaValidator.validate(.object(bad), schema: schema) }
    }

    @Test func schemaPreservesCanonicalExtensionsAndRejectsExternalRefs() throws {
        try MCPJSONSchemaValidator.validate(.object(["customData": .object(["author": .string("test")])]), schema: .object(["type": .string("object")]))
        #expect(throws: MCPJSONRPCError.self) { try MCPJSONSchemaValidator.validate(.object([:]), schema: .object(["$ref": .string("https://example.com/schema.json")])) }
    }

    @Test func configurationUsesDirectHTTPAndTokenComparisonIsExact() {
        let endpoint = "http://127.0.0.1:8490/mcp"
        let codex = ExcalidrawMCPClientConfiguration.configuration(kind: .codex, endpoint: endpoint, token: "private")
        #expect(codex.contains("http_headers")); #expect(codex.contains(endpoint)); #expect(!codex.contains("npx"))
        let claude = ExcalidrawMCPClientConfiguration.configuration(kind: .claudeCode, endpoint: endpoint, token: "private")
        #expect(claude.contains("--transport http")); #expect(claude.contains("--scope user"))
        #expect(ExcalidrawMCPCredentialStore.constantTimeEqual("a-secret", "a-secret"))
        #expect(!ExcalidrawMCPCredentialStore.constantTimeEqual("a-secret", "b-secret"))
    }

    @Test(.timeLimit(.minutes(1))) func releasingSSEIteratorCancelsOnlyItsRequest() async throws {
        let cancelled = MCPTestSignal()
        let secondCancelled = MCPTestSignal()
        let handler = handler(execute: { request, _ in
            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
            catch {
                if request.id == .number(1) { await cancelled.signal() }
                else { await secondCancelled.signal() }
            }
            return .success(id: request.id, result: .object([:]))
        })
        var request = rpc(method: "tools/call", params: ["name": .string("test")])
        var meta = metadata.objectValue!; meta["progressToken"] = .string("test-progress")
        request = MCPJSONRPCRequest(jsonrpc: "2.0", id: request.id, method: request.method, params: .object(["name": .string("test"), "_meta": .object(meta)]))
        let response = try await handler.handleRequest(http(request))
        let second = MCPJSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: request.method, params: request.params)
        let secondResponse = try await handler.handleRequest(http(second))
        #expect(response.headers[.contentType] == "text/event-stream")
        guard case .httpBody(let body) = response.payload else { Issue.record("Expected SSE body"); return }
        guard case .httpBody(let secondBody) = secondResponse.payload else { Issue.record("Expected second SSE body"); return }
        var iterator: HTTPBodySequence.Iterator? = body.makeAsyncIterator()
        var secondIterator: HTTPBodySequence.Iterator? = secondBody.makeAsyncIterator()
        _ = try await iterator?.next()
        _ = try await secondIterator?.next()
        iterator = nil
        await cancelled.wait()
        #expect(!(await secondCancelled.isSignaled()))
        secondIterator = nil
        await secondCancelled.wait()
    }

    @Test(.timeLimit(.minutes(1))) func discardingSSEBeforeBodyIterationCancelsItsRequest() async throws {
        let started = MCPTestSignal()
        let cancelled = MCPTestSignal()
        let handler = handler(execute: { request, _ in
            await started.signal()
            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
            catch { await cancelled.signal() }
            return .success(id: request.id, result: .object([:]))
        })
        var response: HTTPResponse? = try await handler.handleRequest(http(rpc(method: "tools/call", params: ["name": .string("test")])))
        #expect(response?.headers[.contentType] == "text/event-stream")
        await started.wait()
        response = nil
        await cancelled.wait()
    }

    @Test func oversizedBodiesAreRejectedBeforeReadingTheSequence() async throws {
        var request = try http(rpc())
        request.bodySequence = HTTPBodySequence(from: MCPUnreadableBytes(), count: MCPTransportPolicy.maximumBodyBytes + 1)
        #expect(try await handler().handleRequest(request).statusCode == .payloadTooLarge)
    }

    @Test(.timeLimit(.minutes(1))) func legacyCancellationStopsTheMatchingRequest() async throws {
        let cancelled = MCPTestSignal()
        let handler = handler(execute: { request, _ in
            if request.method == "tools/call" {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                catch { await cancelled.signal() }
            }
            return .success(id: request.id, result: .object([:]))
        })
        _ = try await handler.handleRequest(http(rpc(method: "initialize", params: ["protocolVersion": .string("2025-11-25"), "capabilities": .object([:]), "clientInfo": .object(["name": .string("test"), "version": .string("1")])], modern: false)))
        let call = rpc(method: "tools/call", params: ["name": .string("test"), "_meta": .object(["progressToken": .string("legacy-progress")])], modern: false)
        let streamingResponse = try await handler.handleRequest(http(call))
        guard case .httpBody(let body) = streamingResponse.payload else { Issue.record("Expected SSE body"); return }
        var iterator = body.makeAsyncIterator()
        _ = try await iterator.next()
        let cancellation = rpc(method: "notifications/cancelled", params: ["requestId": .number(1)], modern: false, id: nil)
        #expect(try await handler.handleRequest(http(cancellation)).statusCode == .accepted)
        await cancelled.wait()
    }

    @Test func reusedRPCIDsAreNotRemovedByAnOlderCompletion() async throws {
        let registry = MCPActiveRequests()
        let request = rpc(method: "tools/call", params: ["name": .string("test")])
        let old = try await registry.reserve(clientID: "a", request: request)
        await registry.cancel(clientID: "a", requestID: .number(1))
        let replacement = try await registry.reserve(clientID: "a", request: request)
        await registry.complete(old)
        do { _ = try await registry.reserve(clientID: "a", request: request); Issue.record("Replacement request was removed") }
        catch let error as MCPJSONRPCError { #expect(error.code == -32600) }
        _ = try await registry.reserve(clientID: "b", request: request)
        await registry.complete(replacement)
        await registry.cancelAll()
    }
}

private actor MCPTestSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() { signaled = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    func isSignaled() -> Bool { signaled }
    func wait() async {
        guard !signaled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private struct MCPUnreadableBytes: AsyncBufferedSequence {
    typealias Element = UInt8
    func makeAsyncIterator() -> Iterator { Iterator() }
    struct Iterator: AsyncBufferedIteratorProtocol {
        typealias Element = UInt8
        typealias Buffer = [UInt8]
        func next() async throws -> UInt8? { throw UnexpectedRead() }
        func nextBuffer(suggested count: Int) async throws -> [UInt8]? { throw UnexpectedRead() }
    }
    private struct UnexpectedRead: Error {}
}
