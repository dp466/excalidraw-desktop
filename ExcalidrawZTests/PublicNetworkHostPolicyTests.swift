import XCTest
import Network
@testable import ExcalidrawZ

/// AI fetches (web_fetch, image URLs) and the library browser must not reach
/// loopback or private hosts, whatever form the address is written in.
final class PublicNetworkHostPolicyTests: XCTestCase {
    func testNumericFormsOfPrivateAddressesAreRejected() {
        // The plain name check parsed only dotted quads; getaddrinfo accepts
        // these and connects to 127.0.0.1 / 10.0.0.1.
        for host in ["127.1", "2130706433", "0x7f.0.0.1", "0177.0.0.1", "10.1", "127.0.0.1", "[::1]", "::ffff:127.0.0.1", "localhost", "169.254.169.254", "192.168.1.10"] {
            XCTAssertFalse(PublicNetworkHostPolicy.isPublicDestination(host), host)
        }
    }

    func testPublicNumericAddressesAreAllowed() {
        for host in ["1.1.1.1", "8.8.8.8"] {
            XCTAssertTrue(PublicNetworkHostPolicy.isPublicDestination(host), host)
        }
    }

    func testRedirectToPrivateHostIsRefusedBeforeFollowing() throws {
        XCTAssertThrowsError(
            try PublicNetworkFetcher.defaultRedirect(URLRequest(url: URL(string: "http://127.1:8497/")!))
        ) { error in
            XCTAssertEqual(error as? PublicNetworkFetchError, .redirectRefused)
        }
        XCTAssertThrowsError(
            try PublicNetworkFetcher.defaultRedirect(URLRequest(url: URL(string: "file:///etc/hosts")!))
        )
        let allowed = try PublicNetworkFetcher.defaultRedirect(URLRequest(url: URL(string: "https://8.8.8.8/")!))
        XCTAssertEqual(allowed.url?.host, "8.8.8.8")
    }

    /// A normal public HTTPS fetch must still succeed: metrics carry a
    /// public remote address. Skipped when offline.
    func testPublicHTTPSFetchSucceeds() async throws {
        let url = URL(string: "https://example.com/")!
        let result: PublicNetworkFetchResult
        do {
            result = try await PublicNetworkFetcher.fetch(URLRequest(url: url), maxBytes: 64 * 1024, truncatesOverflow: true)
        } catch let error as Foundation.URLError where [.notConnectedToInternet, .timedOut, .cannotFindHost, .networkConnectionLost, .dnsLookupFailed].contains(error.code) {
            throw XCTSkip("offline: \(error.code)")
        }
        XCTAssertEqual(result.response.statusCode, 200)
        XCTAssertFalse(result.data.isEmpty)
    }

    /// The name check passed (as after DNS rebinding) but the connection
    /// landed on loopback: the response must not be returned.
    func testResponseFromLoopbackConnectionIsRefused() async throws {
        let server = try OneShotHTTPServer(body: "secret")
        defer { server.stop() }
        let port = try await server.ready()
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        do {
            _ = try await PublicNetworkFetcher.fetch(URLRequest(url: url), maxBytes: 1024, truncatesOverflow: true)
            XCTFail("loopback response was returned")
        } catch {
            XCTAssertEqual(error as? PublicNetworkFetchError, .nonPublicAddress)
        }
    }
}

/// Minimal HTTP/1.1 server on 127.0.0.1 answering each request with `body`.
private final class OneShotHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let body: String
    private let queue = DispatchQueue(label: "OneShotHTTPServer")

    init(body: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.body = body
    }

    func ready() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { [listener] state in
                guard !resumed else { return }
                switch state {
                    case .ready:
                        resumed = true
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    case .failed(let error):
                        resumed = true
                        continuation.resume(throwing: error)
                    default:
                        break
                }
            }
            listener.newConnectionHandler = { [body, queue] connection in
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }
}
