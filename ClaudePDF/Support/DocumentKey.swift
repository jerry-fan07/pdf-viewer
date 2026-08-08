import Foundation

/// The identity of an opened document, as every per-document store spells it.
///
/// `path|size|modified` — folding in size and modification date means editing or
/// replacing a file silently invalidates whatever was keyed to it (an uploaded
/// `file_id`, a primed session, extracted text, saved history) instead of
/// pointing at state that describes different bytes.
///
/// Read through `FileManager` rather than `URL.resourceValues`: a `URL` caches
/// its resource values on first read, so a URL captured at open time would keep
/// reporting the size and date the file had back then — the exact staleness this
/// key exists to catch.
enum DocumentKey {
    static func make(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? -1
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(path)|\(size)|\(Int(modified))"
    }

    /// A filesystem-safe digest of the key, for use as a file name.
    static func filename(for url: URL) -> String {
        digest(of: make(for: url))
    }

    /// FNV-1a, 64-bit, hex. Not cryptographic — this only has to avoid
    /// collisions between the handful of documents a person opens, and to keep
    /// arbitrary paths out of file names.
    static func digest(of key: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
