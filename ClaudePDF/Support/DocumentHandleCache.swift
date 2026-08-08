import Foundation

/// Remembers the per-document handle a provider produced at attach time —
/// an Anthropic `file_id`, a primed Claude Code `session_id` — so reopening a
/// document doesn't redo the expensive attach.
///
/// The key folds in size and modification date (see `DocumentKey`), so editing or
/// replacing the file silently invalidates the handle instead of pointing at
/// stale server-side state.
struct DocumentHandleCache {
    let namespace: String

    func key(for url: URL) -> String { DocumentKey.make(for: url) }

    func lookup(_ url: URL) -> String? {
        stored()[key(for: url)]
    }

    func store(_ handle: String, for url: URL) {
        var map = stored()
        map[key(for: url)] = handle
        UserDefaults.standard.set(map, forKey: namespace)
    }

    func invalidate(_ url: URL) {
        let key = key(for: url)
        var map = stored()
        map.removeValue(forKey: key)
        UserDefaults.standard.set(map, forKey: namespace)
    }

    private func stored() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: namespace) as? [String: String] ?? [:]
    }
}
