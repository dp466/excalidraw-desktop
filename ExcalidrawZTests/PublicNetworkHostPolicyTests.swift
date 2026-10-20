import XCTest
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

    func testRedirectToPrivateHostIsRefusedBeforeFollowing() {
        let guardDelegate = PublicNetworkRedirectGuard()
        let task = URLSession.shared.dataTask(with: URL(string: "https://1.1.1.1/")!)
        let response = HTTPURLResponse(url: URL(string: "https://1.1.1.1/")!, statusCode: 302, httpVersion: nil, headerFields: nil)!

        var followed: URLRequest?? = .none
        guardDelegate.urlSession(.shared, task: task, willPerformHTTPRedirection: response,
                                 newRequest: URLRequest(url: URL(string: "http://127.1:8497/")!)) { followed = .some($0) }
        XCTAssertEqual(followed, .some(nil))
        XCTAssertTrue(guardDelegate.blockedRedirect)

        let allowed = PublicNetworkRedirectGuard()
        var next: URLRequest?? = .none
        allowed.urlSession(.shared, task: task, willPerformHTTPRedirection: response,
                           newRequest: URLRequest(url: URL(string: "https://8.8.8.8/")!)) { next = .some($0) }
        XCTAssertEqual(next??.url?.host, "8.8.8.8")
        XCTAssertFalse(allowed.blockedRedirect)
        task.cancel()
    }
}
