import Foundation

/// Files API uploads persist until deleted, so a `file_id` stays good across
/// launches — reopening a document never re-sends its bytes.
let anthropicFileCache = DocumentHandleCache(namespace: "anthropic.fileIDs")

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
