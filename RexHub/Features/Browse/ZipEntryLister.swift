import Foundation

/// 压缩包内的一个文件条目。
struct ZipEntry: Identifiable, Hashable {
    let name: String
    let size: Int64

    var id: String { name }
}

/// 只读取 zip 的中央目录列出条目，不解压内容。
enum ZipEntryLister {
    static func entries(at url: URL, limit: Int = 400) throws -> [ZipEntry] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        guard fileSize > 22 else { return [] }

        let tailLength = min(UInt64(65_600), fileSize)
        try handle.seek(toOffset: fileSize - tailLength)
        guard let tail = try handle.read(upToCount: Int(tailLength)) else { return [] }
        guard let eocd = lastEndOfCentralDirectory(in: tail), eocd + 22 <= tail.count else {
            return []
        }

        let directorySize = Int(readUInt32(tail, eocd + 12))
        let directoryOffset = Int(readUInt32(tail, eocd + 16))
        guard directorySize > 0,
              directoryOffset > 0,
              UInt64(directoryOffset) < fileSize else { return [] }

        try handle.seek(toOffset: UInt64(directoryOffset))
        guard let directory = try handle.read(upToCount: directorySize) else { return [] }

        var result: [ZipEntry] = []
        var cursor = 0

        while cursor + 46 <= directory.count, result.count < limit {
            guard readUInt32(directory, cursor) == 0x0201_4B50 else { break }

            let nameLength = Int(readUInt16(directory, cursor + 28))
            let extraLength = Int(readUInt16(directory, cursor + 30))
            let commentLength = Int(readUInt16(directory, cursor + 32))
            let size = Int64(readUInt32(directory, cursor + 24))

            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= directory.count else { break }

            let nameData = directory[
                (directory.startIndex + nameStart)..<(directory.startIndex + nameEnd)
            ]
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
                ?? ""

            if !name.isEmpty, !name.hasSuffix("/") {
                result.append(ZipEntry(name: name, size: size))
            }

            cursor = nameEnd + extraLength + commentLength
        }

        return result
    }

    // MARK: - 字节读取

    private static func lastEndOfCentralDirectory(in data: Data) -> Int? {
        let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        guard data.count >= signature.count else { return nil }

        var index = data.count - signature.count
        while index >= 0 {
            if byte(data, index) == signature[0],
               byte(data, index + 1) == signature[1],
               byte(data, index + 2) == signature[2],
               byte(data, index + 3) == signature[3] {
                return index
            }
            index -= 1
        }
        return nil
    }

    private static func byte(_ data: Data, _ offset: Int) -> UInt8 {
        data[data.startIndex + offset]
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(byte(data, offset)) | (UInt16(byte(data, offset + 1)) << 8)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(byte(data, offset))
            | (UInt32(byte(data, offset + 1)) << 8)
            | (UInt32(byte(data, offset + 2)) << 16)
            | (UInt32(byte(data, offset + 3)) << 24)
    }
}
