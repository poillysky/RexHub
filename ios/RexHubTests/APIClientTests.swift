import XCTest
@testable import RexHub

/// 网络层行为：状态码映射、重试退避、解码容错。全部走 `StubURLProtocol`，不出网。
final class APIClientTests: XCTestCase {
    private let baseURL = URL(string: "http://rexhub.test")!

    override func setUp() {
        super.setUp()
        StubURLProtocol.table.reset()
    }

    // MARK: - 装配

    private func makeClient(maxRetries: Int = 0) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        var client = APIClient(
            baseURL: baseURL,
            token: "token-1",
            session: URLSession(configuration: configuration)
        )
        client.maxRetries = maxRetries
        return client
    }

    private func envelope(_ userJSON: String) -> Data {
        Data("{\"data\":\(userJSON),\"message\":\"\",\"status\":200}".utf8)
    }

    // MARK: - 正常路径

    func testCurrentUserDecodesEnvelope() async throws {
        StubURLProtocol.table.enqueue(
            [.init(status: 200, body: envelope("{\"id\":\"u1\",\"username\":\"demo\",\"is_admin\":true}"))],
            for: "/api/auth/me"
        )

        let user = try await makeClient().currentUser()

        XCTAssertEqual(user.id, "u1")
        XCTAssertEqual(user.name, "demo")
        XCTAssertTrue(user.isAdmin)
        XCTAssertEqual(StubURLProtocol.table.hitCount("/api/auth/me"), 1)
    }

    // MARK: - 状态码 → APIError

    func testStatusCodesMapToTypedErrors() async {
        let cases: [(status: Int, headers: [String: String], expected: APIError)] = [
            (401, [:], .unauthorized),
            (403, [:], .forbidden),
            (404, [:], .notFound),
            (429, ["Retry-After": "2"], .rateLimited(retryAfter: 2)),
            (500, [:], .server(status: 500)),
            (503, [:], .server(status: 503)),
        ]

        for item in cases {
            StubURLProtocol.table.reset()
            StubURLProtocol.table.enqueue(
                [.init(status: item.status, headers: item.headers)],
                for: "/api/auth/me"
            )

            do {
                _ = try await makeClient().currentUser()
                XCTFail("\(item.status) 应当抛错")
            } catch let error as APIError {
                XCTAssertEqual(error, item.expected, "\(item.status)")
            } catch {
                XCTFail("\(item.status) 抛出了非 APIError：\(error)")
            }
        }
    }

    func testMalformedBodyThrowsDecodingError() async {
        StubURLProtocol.table.enqueue(
            [.init(status: 200, body: Data("not json".utf8))],
            for: "/api/auth/me"
        )

        do {
            _ = try await makeClient().currentUser()
            XCTFail("坏 JSON 应当抛错")
        } catch let error as APIError {
            XCTAssertEqual(error, .decoding)
        } catch {
            XCTFail("抛出了非 APIError：\(error)")
        }
    }

    // MARK: - 重试

    func testRetriesServerErrorsThenSucceeds() async throws {
        StubURLProtocol.table.enqueue(
            [
                .init(status: 500),
                .init(status: 502),
                .init(status: 200, body: envelope("{\"id\":\"u1\",\"username\":\"demo\"}")),
            ],
            for: "/api/auth/me"
        )

        let user = try await makeClient(maxRetries: 2).currentUser()

        XCTAssertEqual(user.name, "demo")
        XCTAssertEqual(StubURLProtocol.table.hitCount("/api/auth/me"), 3)
    }

    func testStopsRetryingAfterBudget() async {
        StubURLProtocol.table.enqueue([.init(status: 500)], for: "/api/auth/me")

        do {
            _ = try await makeClient(maxRetries: 1).currentUser()
            XCTFail("应当耗尽重试后抛错")
        } catch let error as APIError {
            XCTAssertEqual(error, .server(status: 500))
        } catch {
            XCTFail("抛出了非 APIError：\(error)")
        }
        // 首次 + 1 次重试 = 2 次请求。
        XCTAssertEqual(StubURLProtocol.table.hitCount("/api/auth/me"), 2)
    }

    func testUnauthorizedIsNeverRetried() async {
        StubURLProtocol.table.enqueue([.init(status: 401)], for: "/api/auth/me")

        do {
            _ = try await makeClient(maxRetries: 3).currentUser()
            XCTFail("401 应当直接抛出")
        } catch let error as APIError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("抛出了非 APIError：\(error)")
        }
        XCTAssertEqual(StubURLProtocol.table.hitCount("/api/auth/me"), 1)
    }
}
