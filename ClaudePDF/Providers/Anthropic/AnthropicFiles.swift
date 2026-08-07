import Foundation

/// Remembers which `file_id` a local PDF was uploaded as, so reopening a document
/// doesn't re-send its bytes. Files API uploads persist until deleted, so the id
/// stays good across launches; the key changes if the file is edited or replaced.
enum AnthropicFileCache {
    private static let defaultsKey = "anthropic.fileIDs"

    static func key(for url: URL) -> String? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? -1
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? -1
        guard size >= 0 else { return nil }
        return "\(url.standardizedFileURL.path)|\(size)|\(Int(modified))"
    }

    static func lookup(_ url: URL) -> String? {
        guard let key = key(for: url) else { return nil }
        return stored()[key]
    }

    static func store(_ fileID: String, for url: URL) {
        guard let key = key(for: url) else { return }
        var map = stored()
        map[key] = fileID
        UserDefaults.standard.set(map, forKey: defaultsKey)
    }

    static func invalidate(_ url: URL) {
        guard let key = key(for: url) else { return }
        var map = stored()
        map.removeValue(forKey: key)
        UserDefaults.standard.set(map, forKey: defaultsKey)
    }

    private static func stored() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }
}

/// Minimal `multipart/form-data` body for `POST /v1/files`.
enum AnthropicMultipart {
    static func body(fileData: Data, filename: String, mimeType: String, boundary: String) -> Data {
        var body = Data()
        body.appendASCII("--\(boundary)\r\n")
        body.appendASCII("Content-Disposition: form-data; name=\"file\"; filename=\"\(sanitize(filename))\"\r\n")
        body.appendASCII("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        body.appendASCII("\r\n--\(boundary)--\r\n")
        return body
    }

    /// Quotes and newlines would break the Content-Disposition header.
    static func sanitize(_ filename: String) -> String {
        let cleaned = filename.replacingOccurrences(of: "\"", with: "")
            .components(separatedBy: .newlines)
            .joined(separator: " ")
        return cleaned.isEmpty ? "document.pdf" : cleaned
    }
}

extension Data {
    fileprivate mutating func appendASCII(_ string: String) {
        append(Data(string.utf8))
    }
}
