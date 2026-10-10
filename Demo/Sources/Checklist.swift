import Combine
import Foundation
import Recached

/// One checklist item, stored as a JSON string under `todo:<created>-<random>`.
struct Item: Identifiable, Equatable {
    let key: String
    let title: String
    let done: Bool
    var id: String { key }

    init?(_ entry: Entry) {
        guard let data = entry.value,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let title = json["title"] as? String
        else { return nil }
        key = entry.key
        self.title = title
        done = json["done"] as? Bool ?? false
    }

    static func json(title: String, done: Bool) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["title": title, "done": done], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

/// The whole app's data, on top of `Recached`. Every write is local first: it
/// shows at once, is saved before the call returns, and syncs when it can.
@MainActor
final class Checklist: ObservableObject {
    static let pattern = "todo:*"

    @Published private(set) var items: [Item] = []
    @Published private(set) var connection: ConnectionState = .offline
    @Published private(set) var pending = 0
    let server: String

    private let cache: Recached
    private var feeds: [Task<Void, Never>] = []

    /// Opens the cache. Launch arguments (`-server ws://…`, `-reset YES`)
    /// arrive through UserDefaults, which is how the UI tests drive it.
    static func open() -> Checklist {
        let defaults = UserDefaults.standard
        let server = defaults.string(forKey: "server") ?? "ws://127.0.0.1:6380"
        if defaults.bool(forKey: "reset") { deleteStore() }
        let cache = try! Recached.open(named: "checklist", config: RecachedConfig(url: URL(string: server)))
        // Not remembered across opens: say what to keep in sync every time.
        cache.watch(pattern)
        return Checklist(cache: cache, server: server)
    }

    private init(cache: Recached, server: String) {
        self.cache = cache
        self.server = server
        feeds = [
            Task { [weak self] in
                for await entries in cache.observeMatching(Self.pattern) {
                    self?.items = entries.compactMap(Item.init)
                }
            },
            Task { [weak self] in
                for await state in cache.connectionStates() { self?.connection = state }
            },
            Task { [weak self] in
                for await count in cache.pendingWriteCounts() { self?.pending = count }
            },
        ]
    }

    deinit {
        for feed in feeds { feed.cancel() }
    }

    func add(_ title: String) {
        let text = title.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        // Zero-padded time first, so keys sort in creation order across devices.
        let millis = Int(Date().timeIntervalSince1970 * 1000)
        let key = String(format: "todo:%013d-%04x", millis, Int.random(in: 0..<0x10000))
        try? cache.set(key, Item.json(title: text, done: false))
    }

    func toggle(_ item: Item) {
        try? cache.set(item.key, Item.json(title: item.title, done: !item.done))
    }

    func delete(_ item: Item) {
        _ = try? cache.delete(item.key)
    }

    private static func deleteStore() {
        guard
            let directory = try? FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                .appendingPathComponent("Recached")
        else { return }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("checklist.db\(suffix)"))
        }
    }
}
