import Foundation

/// 把网络请求挡在测试进程里：按路径依次吐出预设响应，并统计命中次数。
final class StubURLProtocol: URLProtocol {
    struct Stub: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
    }

    /// 桩表：路径 → 待出栈的响应。只剩一条时重复使用。
    /// 内部状态全部由 `lock` 保护，因此对并发访问安全。
    final class Table: @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [String: [Stub]] = [:]
        private var hits: [String: Int] = [:]

        func reset() {
            lock.lock()
            defer { lock.unlock() }
            queue.removeAll()
            hits.removeAll()
        }

        func enqueue(_ stubs: [Stub], for path: String) {
            lock.lock()
            defer { lock.unlock() }
            queue[path] = stubs
        }

        func next(for path: String) -> Stub? {
            lock.lock()
            defer { lock.unlock() }
            hits[path, default: 0] += 1
            guard var list = queue[path], !list.isEmpty else { return nil }
            let stub = list.count > 1 ? list.removeFirst() : list[0]
            queue[path] = list
            return stub
        }

        func hitCount(_ path: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return hits[path] ?? 0
        }
    }

    static let table = Table()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let stub = Self.table.next(for: url.path) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
