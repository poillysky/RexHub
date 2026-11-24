import XCTest
@testable import RexHub

/// 服务端返回 `is_admin`，本地会话文件存 `isAdmin`，两个解码入口都要能读。
final class AuthUserDecodingTests: XCTestCase {
    func testDecodesServerShapeWithSnakeCaseAdminFlag() throws {
        let json = Data("{\"id\":\"u1\",\"username\":\"demo\",\"is_admin\":true}".utf8)
        let user = try JSONDecoder().decode(AuthUser.self, from: json)

        XCTAssertEqual(user.id, "u1")
        XCTAssertEqual(user.name, "demo")
        XCTAssertTrue(user.isAdmin)
    }

    func testDecodesNumericIDAndLocalShape() throws {
        let json = Data("{\"id\":42,\"name\":\"cached\",\"isAdmin\":false}".utf8)
        let user = try JSONDecoder().decode(AuthUser.self, from: json)

        XCTAssertEqual(user.id, "42")
        XCTAssertEqual(user.name, "cached")
        XCTAssertFalse(user.isAdmin)
    }

    func testRoundTripsThroughEncoder() throws {
        let original = AuthUser(id: "u9", name: "round", isAdmin: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AuthUser.self, from: data)

        XCTAssertEqual(decoded, original)
    }
}
