import Foundation

/// 网络传输边界：需要发请求的地方都从这里取 session，业务代码不再直接引用 `URLSession.shared`。
/// 换代理、调超时、或注册 `URLProtocol` 桩做测试时，只改这一处。
enum HTTPTransport {
    /// 业务 API：JSON、SSE、上传。单请求超时由各自覆盖，这里只给兜底值。
    /// 资源超时留得很宽：SSE 对话与 600s 上传不能被一次总时限掐断。
    static let api: URLSession = make(requestTimeout: 15, resourceTimeout: 3600, connections: 8)

    /// 媒体与缩略图：直链、外部字幕、封面。与 API 会话分开，
    /// 退出登录取消在途请求时不会误伤正在下载的文件。
    /// 资源超时同样放宽：115 上的大文件可能下一小时，真正的边界由单请求超时管。
    static let transfer: URLSession = make(requestTimeout: 30, resourceTimeout: 3600, connections: 6)

    /// 供测试注入：`URLProtocol` 桩挂在自定义 configuration 上，再传给 `APIClient(session:)`。
    static func make(
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval,
        connections: Int
    ) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.httpMaximumConnectionsPerHost = connections
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}

/// 一条逐行响应（SSE）的句柄：状态码先到手，正文边到边解析。
struct HTTPLineStream: Sendable {
    /// `0` 表示响应不是 HTTP。
    let statusCode: Int
    let lines: AsyncThrowingStream<String, Error>
}

extension URLSession {
    /// 把 `bytes(for:)` 拆成「状态码 + 逐行流」；流被丢弃或读完时同步取消底层请求。
    func lineStream(for request: URLRequest) async throws -> HTTPLineStream {
        let (bytes, response) = try await bytes(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPLineStream(statusCode: statusCode, lines: lines)
    }
}
