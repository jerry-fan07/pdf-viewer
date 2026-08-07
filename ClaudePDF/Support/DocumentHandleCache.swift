import Foundation

/// Remembers the per-document handle a provider produced at attach time —
/// an Anthropic `file_id`, a primed Claude Code `session_id` — so reopening a
/// document doesn't redo the expensive attach.
///
/// The key folds in size and modification date, so editing or replacing the file
/// silently invalidates the handle instead of pointing at stale server-side state.
struct DocumentHandleCache {
    let namespace: String

    func key(for url: URL) -> String? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values?.fileSize else { return nil }
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? -1
        return "\(url.standardizedFileURL.path)|\(size)|\(Int(modified))"
    }

    func lookup(_ url: URL) -> String? {
        guard let key = key(for: url) else { return nil }
        return stored()[key]
    }

    func store(_ handle: String, for url: URL) {
        guard let key = key(for: url) else { return }
        var map = stored()
        map[key] = handle
        UserDefaults.standard.set(map, forKey: namespace)
    }

    func invalidate(_ url: URL) {
        guard let key = key(for: url) else { return }
        var map = stored()
        map.removeValue(forKey: key)
        UserDefaults.standard.set(map, forKey: namespace)
    }

    private func stored() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: namespace) as? [String: String] ?? [:]
    }
}
