import Foundation
import UIKit

/// 网盘文件直链下载：先用 pickcode 换直链，再带上 115 要求的请求头取回字节。
enum PanRemoteFile {
    /// 下载到临时目录，文件名保留原扩展名，方便 QuickLook / 解压识别。
    static func download(item: PanItem, client: APIClient) async throws -> URL {
        let request = try await makeRequest(item: item, client: client, timeout: 300)
        let (tempURL, response) = try await URLSession.shared.download(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw APIError.server(status: http.statusCode)
        }

        let name = item.name.isEmpty ? "file" : item.name
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let destination = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    static func imageData(item: PanItem, client: APIClient) async throws -> Data {
        let request = try await makeRequest(item: item, client: client, timeout: 60)
        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw APIError.server(status: http.statusCode)
        }
        return data
    }

    private static func makeRequest(
        item: PanItem,
        client: APIClient,
        timeout: TimeInterval
    ) async throws -> URLRequest {
        let info = try await client.panPlay(pickcode: item.pickcode)
        var request = URLRequest(url: info.url)
        for (key, value) in info.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.timeoutInterval = timeout
        return request
    }
}
