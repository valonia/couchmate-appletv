import Foundation

/// An entry in the menu: built in (favorites, history) or from a plugin.
struct MenuEntry: Identifiable, Equatable {
    let core: String?
    let plugin: String?
    let id: String
    let title: String
    let icon: String?
    var key: String { core != nil ? "core/\(core!)" : "\(plugin ?? "")/\(id)" }
}

/// Anything a plugin shows: a channel, movie, series, episode, stream …
struct Item: Identifiable, Equatable {
    let plugin: String
    let id: String
    var title: String
    var subtitle: String? = nil
    var image: String? = nil
    var backdrop: String? = nil
    var description: String? = nil
    var kind: String? = nil
    /// "play" (default) or "open" (the plugin's view `view` with params { id }).
    var action: String = "play"
    var view: String? = nil
    var live: Bool = false
    var number: Int? = nil
    var viewers: Int? = nil
    var year: String? = nil
    var genre: String? = nil
    var rating: Double? = nil
    var badge: String? = nil
    var duration: Double? = nil
    var favorite: Bool = true
    /// Shown but cannot be played (e.g. a song that was not found): greyed out and skipped.
    var unavailable: Bool = false

    var key: String { "\(plugin):\(id)" }
    var opens: Bool { action == "open" }
}

func parseItem(_ o: JSON, plugin fallback: String? = nil) -> Item? {
    guard let plugin = o.str("plugin") ?? fallback, let id = o.str("id") else { return nil }
    return Item(
        plugin: plugin, id: id, title: o.str("title") ?? id, subtitle: o.str("subtitle"), image: o.str("image"),
        backdrop: o.str("backdrop"), description: o.str("description"), kind: o.str("kind"),
        action: o.str("action") ?? "play", view: o.str("view"), live: o.bool("live"), number: o.int("number"),
        viewers: o.int("viewers"), year: o.str("year"), genre: o.str("genre"), rating: o.double("rating"),
        badge: o.str("badge"), duration: o.double("duration"), favorite: o.bool("favorite", true),
        unavailable: o.bool("unavailable")
    )
}

struct ItemRow: Identifiable {
    let id: String
    let title: String?
    let style: String
    let items: [Item]
}

func parseRows(_ a: [JSON], plugin: String?) -> [ItemRow] {
    a.map { r in ItemRow(id: r.string("id"), title: r.str("title"), style: r.str("style") ?? "landscape", items: r.objects("items").compactMap { parseItem($0, plugin: plugin) }) }
}

struct PluginResult: Identifiable {
    let plugin: String
    let name: String
    let sections: [ItemRow]
    var id: String { plugin }
}

struct Program: Equatable {
    let title: String
    let description: String?
    let start: Int64
    let end: Int64
    func isNow(_ now: Int64) -> Bool { now >= start && now < end }
    func progress(_ now: Int64) -> Double { end > start ? min(1, max(0, Double(now - start) / Double(end - start))) : 0 }
}

func parsePrograms(_ a: [JSON]) -> [Program] {
    a.map { Program(title: $0.string("title"), description: $0.str("description"), start: $0.int64("start"), end: $0.int64("end")) }
}

extension Array where Element == Program {
    func now(_ t: Int64) -> Program? { first { $0.isNow(t) } }
    func next(_ t: Int64) -> Program? { first { $0.start > t } }
}

func nowSec() -> Int64 { Int64(Date().timeIntervalSince1970) }

struct HistoryEntry: Identifiable {
    let key: String
    let plugin: String
    let id: String
    let kind: String?
    let title: String
    let subtitle: String?
    let image: String?
    let live: Bool
    let startedBy: String?
    let lastAt: Int64
    let position: Double
    let duration: Double?
    var fraction: Double { if let d = duration, d > 0 { return min(1, max(0, position / d)) }; return 0 }
    var finished: Bool { if let d = duration, d > 0 { return position >= d * 0.95 }; return false }
    /// Worth resuming: more than a minute in and not nearly finished.
    var resumable: Bool { !live && position > 60 && !finished }
    func toItem() -> Item { Item(plugin: plugin, id: id, title: title, subtitle: subtitle, image: image, kind: kind, live: live) }
}

/// A group on the Favorites screen, named by the plugin. style: poster | landscape | guide.
struct FavGroup: Equatable {
    let id: String
    let title: String
    let order: Double
    let style: String
    static let other = FavGroup(id: "other", title: "Other", order: 99, style: "landscape")
}

/// A favourite in the room. `newCount` new episodes since someone last looked, e.g. `newLabel` = "S03E05".
struct Favorite: Identifiable, Equatable {
    let key: String
    let plugin: String
    let id: String
    let kind: String?
    let title: String
    let subtitle: String?
    let image: String?
    let live: Bool
    let action: String
    let view: String?
    let addedBy: String?
    let newCount: Int
    let newLabel: String?
    let viewers: Int?
    let group: FavGroup
    func toItem() -> Item { Item(plugin: plugin, id: id, title: title, subtitle: subtitle, image: image, kind: kind, action: action, view: view, live: live, viewers: viewers) }
}

/// "Switch to this channel when the programme starts" – shared by the room.
struct Reminder: Identifiable, Equatable {
    let key: String
    let plugin: String
    let channel: Item
    let title: String
    let desc: String?
    let start: Int64
    let end: Int64
    let addedBy: String?
    var id: String { key }
}

func reminderKey(_ plugin: String, _ channelId: String, _ start: Int64) -> String { "\(plugin):\(channelId):\(start)" }

struct SpecOption: Equatable { let id: String; let label: String }
struct SpecSection: Equatable {
    let id: String
    let type: String
    let title: String?
    var options: [SpecOption] = []
    var defaultValue: String? = nil
}

/// How the player looks and reacts, decided by the plugin.
/// keys: what OK/▲/▼/◀/▶ do – pause, settings, chat, info, channels, channel_up, channel_down, seek_back, seek_forward, queue, none.
struct PlayerSpec {
    let keys: [String: String]
    let settings: [SpecSection]
    let channels: Bool
    let guide: Bool
    var overlay: JSON? = nil
    var queue: Bool = false
}

/// What plays next (the plugin's data('queue')): `current` is the item playing now.
struct Queue {
    let title: String?
    let current: String?
    let items: [Item]
}

struct Media {
    let plugin: String
    let id: String
    let kind: String?
    let title: String
    let subtitle: String?
    let image: String?
    let live: Bool
    let url: String
    /// "hls" or "file" – the address has no file extension.
    let type: String
    /// The video has a separate audio file (same address with part=audio) that plays together with it.
    let audio: Bool
    /// The plugin has captions for it (same address with part=captions) – shown when CC is on on this TV.
    var captions: Bool = false
    let chat: Bool
    let player: PlayerSpec?
    var key: String { "\(plugin):\(id)" }
    func toItem() -> Item { Item(plugin: plugin, id: id, title: title, subtitle: subtitle, image: image, kind: kind, live: live) }
    /// For the plugin's overlay ({{media.title}} …).
    func toJSON() -> JSON {
        var o: JSON = ["plugin": plugin, "id": id, "title": title, "live": live]
        if let kind { o["kind"] = kind }
        if let subtitle { o["subtitle"] = subtitle }
        if let image { o["image"] = image }
        return o
    }
}

/// "Next", starting by itself at `startsAt` (server clock, ms).
struct UpNext {
    let item: Item
    let startsAt: Int64
    /// Shown before the end (music): the next one follows straight on when this one ends.
    let early: Bool
    let media: Media?
}

struct PreparedNext { let item: Item; let media: Media }

/// A reminder that is about to switch everyone at `switchAt` (server clock, ms).
struct PendingReminder {
    let key: String
    let title: String
    let start: Int64
    let channelTitle: String
    let channelImage: String?
    let switchAt: Int64
}

struct RoomState {
    let media: Media?
    let paused: Bool
    let waiting: Bool
    let position: Double
    let refTime: Int64
    let version: Int
    let changedBy: String?
    let action: String?
    let upNext: UpNext?
    let reminder: PendingReminder?
    let preparedNext: PreparedNext?
}

struct Member: Identifiable, Equatable {
    let id: String
    let name: String
    let device: String
    let watching: Bool
}

/// A chat message from a live stream.
struct ChatMsg: Identifiable, Equatable {
    let id = UUID()
    let user: String
    let color: String?
    let text: String
}

// MARK: - formatting

func normalizeUrl(_ input: String) -> String {
    var u = input.trimmingCharacters(in: .whitespacesAndNewlines)
    while u.hasSuffix("/") { u.removeLast() }
    if !u.hasPrefix("http://") && !u.hasPrefix("https://") { u = "http://" + u }
    return u
}

func formatTime(_ sec: Double) -> String {
    let s = Int(max(0, sec))
    let h = s / 3600, m = (s % 3600) / 60, r = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
}

/// Unique keys for a list of items (a plugin may list the same item twice – e.g. a song that comes back in a Mix).
func uniqueKeys(_ items: [Item]) -> [String] {
    var seen = Set<String>()
    return items.enumerated().map { i, it in seen.insert(it.key).inserted ? it.key : "\(it.key)#\(i)" }
}
