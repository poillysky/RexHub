import XCTest
@testable import RexHub

/// 服务端地址解析：决定 App 能不能连上，纯函数，最容易回归。
final class ServerConfigTests: XCTestCase {
    func testResolveAddsSchemeAndKeepsPort() {
        XCTAssertEqual(
            ServerConfig.resolve("192.168.1.10:8020", useHTTPS: false)?.absoluteString,
            "http://192.168.1.10:8020"
        )
        XCTAssertEqual(
            ServerConfig.resolve("192.168.1.10:8020", useHTTPS: true)?.absoluteString,
            "https://192.168.1.10:8020"
        )
    }

    func testResolveAcceptsDomainAndLocalhost() {
        XCTAssertEqual(
            ServerConfig.resolve("hub.example.com", useHTTPS: true)?.host,
            "hub.example.com"
        )
        XCTAssertEqual(
            ServerConfig.resolve("localhost:8020", useHTTPS: false)?.host,
            "localhost"
        )
    }

    func testResolveTrimsTrailingSlash() {
        XCTAssertEqual(
            ServerConfig.resolve("hub.example.com/nested/", useHTTPS: true)?.absoluteString,
            "https://hub.example.com/nested"
        )
    }

    func testResolveRejectsInvalidInput() {
        XCTAssertNil(ServerConfig.resolve("", useHTTPS: false))
        XCTAssertNil(ServerConfig.resolve("   ", useHTTPS: false))
        XCTAssertNil(ServerConfig.resolve("nohost", useHTTPS: false))
    }

    /// 当前行为：写法里的协议被开关覆盖，协议由 `useHTTPS` 决定。
    func testExplicitSchemeIsOverriddenByToggle() {
        XCTAssertEqual(ServerConfig.resolve("https://hub.example.com", useHTTPS: false)?.scheme, "http")
        XCTAssertEqual(ServerConfig.resolve("http://hub.example.com", useHTTPS: true)?.scheme, "https")
    }

    func testExplicitHTTPSDetection() {
        XCTAssertEqual(ServerConfig.explicitHTTPS(in: "https://a.example.com"), true)
        XCTAssertEqual(ServerConfig.explicitHTTPS(in: "HTTP://a.example.com"), false)
        XCTAssertNil(ServerConfig.explicitHTTPS(in: "a.example.com:8020"))
    }
}
