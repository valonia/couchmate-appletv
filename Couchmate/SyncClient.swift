import Foundation
import UIKit

/// WebSocket client for the room. Keeps the room's state and an estimate of the difference between this device's
/// clock and the server's (NTP-like, the lowest round trip wins).
@MainActor
final class SyncClient: ObservableObject {
    let api: Api
    private let base: String
    private let pin: String
    private let name: String
    private let device: String

    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var running = false
    private var offsetMs: Int64 = 0
    private(set) var watching = false
    private var chatOn = false
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var samples = [(rtt: Int64, offset: Int64)]()

    @Published var state: RoomState?
    @Published var members: [Member] = []
    @Published var connected = false
    @Published var error: String?
    @Published var favorites: [Favorite] = []
    @Published var reminders: [Reminder] = []
    /// Counts up when the server says the menu changed (plugins, order, translations).
    @Published var menuVersion = 0
    /// Counts up when the server has new translations: the open view is fetched again.
    @Published var textsVersion = 0
    @Published var historyVersion = 0
    /// Live chat for the stream that plays (only while it is shown).
    @Published var chat: [ChatMsg] = []
    /// A short message from the server or a plugin (shown as a toast).
    @Published var notice: (Date, String)?

    init(api: Api, base: String, pin: String, name: String) {
        self.api = api
        self.base = base
        self.pin = pin
        self.name = name
        self.device = UIDevice.current.name.isEmpty ? "Apple TV" : UIDevice.current.name
    }

    func serverNow() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) + offsetMs }

    func start() {
        if running { return }
        running = true
        open()
    }

    func stop() {
        running = false
        reconnectTask?.cancel()
        pingTask?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        connected = false
    }

    private func open() {
        let wsBase = base.replacingOccurrences(of: "^http", with: "ws", options: .regularExpression)
        guard let url = URL(string: wsBase + "/ws?pin=" + enc(pin)) else { error = tr("Invalid server address"); return }
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        samples = []
        send(["type": "hello", "name": name, "device": device, "lang": I18n.shared.lang ?? "en"])
        if watching { send(["type": "watching", "value": true]) }
        if chatOn { send(["type": "chat_sub", "on": true]) }
        receive(t)
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            for _ in 0..<5 { self?.ping(); try? await Task.sleep(nanoseconds: 300_000_000) }
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000_000); self?.ping() }
        }
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === t else { return }
                switch result {
                case .success(let msg):
                    if !self.connected { self.connected = true; self.error = nil }
                    switch msg {
                    case .string(let s): self.handle(s)
                    case .data(let d): if let s = String(data: d, encoding: .utf8) { self.handle(s) }
                    @unknown default: break
                    }
                    self.receive(t)
                case .failure:
                    let code = t.closeCode.rawValue
                    let http = (t.response as? HTTPURLResponse)?.statusCode
                    self.lost(t, code == 4001 ? tr("The PIN code has changed – enter the new one in Settings")
                        : http == 401 ? tr("Wrong PIN code") : http == 503 ? tr("The server is not set up yet") : tr("Connection lost"))
                }
            }
        }
    }

    private func lost(_ t: URLSessionWebSocketTask, _ msg: String?) {
        guard t === task else { return }
        connected = false
        pingTask?.cancel()
        if let msg { error = msg }
        guard running else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.running, self.task === t else { return }
            self.open()
        }
    }

    /// The language changed in Settings: the server sends text in the new language from now on.
    func languageChanged() { send(["type": "lang", "lang": I18n.shared.lang ?? "en"]) }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8), let o = parseJSON(data) as? JSON else { return }
        switch o.string("type") {
        case "pong":
            let t = o.int64("t"), s = o.int64("s")
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let rtt = now - t
            samples.append((rtt, s - (t + rtt / 2)))
            if samples.count > 12 { samples.removeFirst() }
            offsetMs = samples.min { $0.rtt < $1.rtt }?.offset ?? 0
        case "state":
            if let s = o.obj("state") { state = parseState(s) }
        case "chat":
            let msgs = o.objects("messages").map { ChatMsg(user: $0.string("user"), color: $0.str("color"), text: $0.string("text")) }
            chat = Array(((o.bool("reset") ? [] : chat) + msgs).suffix(150))
        case "favorites":
            favorites = o.objects("favorites").map(parseFavorite)
        case "reminders":
            reminders = o.objects("reminders").map { r in
                let plugin = r.string("plugin")
                let c = r.obj("channel") ?? [:]
                return Reminder(
                    key: r.string("key"), plugin: plugin,
                    channel: Item(plugin: plugin, id: c.string("id"), title: c.string("title"), image: c.str("image"), kind: "channel", live: true),
                    title: r.string("title"), desc: r.str("desc"), start: r.int64("start"), end: r.int64("end"), addedBy: r.str("addedBy")
                )
            }
        case "members":
            members = o.objects("members").map { Member(id: $0.string("id"), name: $0.string("name"), device: $0.string("device"), watching: $0.bool("watching")) }
        case "menu_changed": menuVersion += 1
        case "texts_changed": textsVersion += 1; menuVersion += 1
        case "translations_changed": I18n.shared.invalidate(o.str("lang")); menuVersion += 1
        case "translations_version": if I18n.shared.checkVersion(o.str("lang"), o.string("version")) { menuVersion += 1 }
        case "history_changed": historyVersion += 1
        case "notice", "error": if let t = o.str("text") { notice = (Date(), t) }
        default: break
        }
    }

    private func parseFavorite(_ f: JSON) -> Favorite {
        // status = what the plugin says now (e.g. a Twitch channel live or offline) – over what was saved.
        let st = f.obj("status")
        let g = f.obj("group")
        return Favorite(
            key: f.string("key"), plugin: f.string("plugin"), id: f.string("id"), kind: f.str("kind"),
            title: st?.str("title") ?? f.string("title"), subtitle: st?.str("subtitle") ?? f.str("subtitle"),
            image: st?.str("image") ?? f.str("image"), live: st?.has("live") == true ? st!.bool("live") : f.bool("live"),
            action: f.str("action") ?? "play", view: f.str("view"), addedBy: f.str("addedBy"),
            newCount: f.int("newCount") ?? 0, newLabel: f.str("newLabel"), viewers: st?.int("viewers"),
            group: g.map { FavGroup(id: $0.str("id") ?? "other", title: $0.str("title") ?? tr("Other"), order: $0.double("order") ?? 99, style: $0.str("style") ?? "landscape") } ?? .other
        )
    }

    private func parsePlayerSpec(_ o: JSON) -> PlayerSpec {
        let k = o.obj("keys") ?? [:]
        var keys = [String: String]()
        for key in ["ok", "up", "down", "left", "right"] { keys[key] = k.str(key) ?? "none" }
        let settings = o.objects("settings").map { s in
            SpecSection(id: s.string("id"), type: s.string("type"), title: s.str("title"),
                        options: s.objects("options").map { SpecOption(id: $0.string("id"), label: $0.string("label")) },
                        defaultValue: s.str("default"))
        }
        return PlayerSpec(keys: keys, settings: settings, channels: o.bool("channels"), guide: o.bool("guide"), overlay: o.obj("overlay"), queue: o.bool("queue"))
    }

    private func parseMedia(_ j: JSON) -> Media {
        Media(
            plugin: j.string("plugin"), id: j.string("id"), kind: j.str("kind"), title: j.string("title"), subtitle: j.str("subtitle"),
            image: j.str("image"), live: j.bool("live"), url: api.abs(j.str("url")) ?? j.string("url"), type: j.str("type") ?? "file",
            audio: j.bool("audio"), chat: j.bool("chat"), player: j.obj("player").map(parsePlayerSpec)
        )
    }

    private func parseState(_ o: JSON) -> RoomState {
        let upNext: UpNext? = o.obj("upNext").flatMap { u in
            u.obj("item").flatMap { parseItem($0) }.map { UpNext(item: $0, startsAt: u.int64("startsAt"), early: u.bool("early"), media: u.obj("media").map(parseMedia)) }
        }
        let prepared: PreparedNext? = o.obj("preparedNext").flatMap { p in
            guard let item = p.obj("item").flatMap({ parseItem($0) }), let m = p.obj("media") else { return nil }
            return PreparedNext(item: item, media: parseMedia(m))
        }
        let reminder: PendingReminder? = o.obj("reminder").map { r in
            let c = r.obj("channel") ?? [:]
            return PendingReminder(key: r.string("key"), title: r.string("title"), start: r.int64("start"), channelTitle: c.string("title"), channelImage: c.str("image"), switchAt: r.int64("switchAt"))
        }
        return RoomState(
            media: o.obj("media").map(parseMedia), paused: o.bool("paused"), waiting: o.bool("waiting"),
            position: o.double("position") ?? 0, refTime: o.int64("refTime"), version: o.int("version") ?? 0,
            changedBy: o.str("changedBy"), action: o.str("action"), upNext: upNext, reminder: reminder, preparedNext: prepared
        )
    }

    private func send(_ o: JSON) {
        task?.send(.string(toJSONString(o))) { _ in }
    }

    private func ping() { send(["type": "ping", "t": Int64(Date().timeIntervalSince1970 * 1000)]) }

    // MARK: - commands

    /// Plays an item for everyone. `position` = where to start (seconds), e.g. when resuming.
    func load(_ item: Item, position: Double = 0) {
        if item.unavailable { return } // greyed out: shown, never played
        var meta: JSON = ["title": item.title, "live": item.live]
        if let s = item.subtitle { meta["subtitle"] = s }
        if let s = item.image { meta["image"] = s }
        if let s = item.kind { meta["kind"] = s }
        send(["type": "load", "plugin": item.plugin, "id": item.id, "position": position, "meta": meta])
    }

    func play() { send(["type": "play"]) }
    func pause() { send(["type": "pause"]) }
    func toggle() { send(["type": "toggle"]) }
    func stopPlayback() { send(["type": "stop"]) }
    func seek(_ position: Double) { send(["type": "seek", "position": position]) }
    func ready(_ version: Int, duration: Double = 0) { send(["type": "ready", "version": version, "duration": duration]) }
    func duration(_ value: Double) { send(["type": "duration", "value": value]) }
    func report(_ position: Double, status: String) { send(["type": "report", "position": position, "status": status, "at": serverNow()]) }
    func playerAction(_ action: String) { send(["type": "player_action", "action": action]) }

    /// Show the chat (the server only sends chat to those who show it).
    func setChat(_ on: Bool) {
        if chatOn == on { return }
        chatOn = on
        if !on { chat = [] }
        send(["type": "chat_sub", "on": on])
    }

    func setWatching(_ value: Bool) {
        watching = value
        send(["type": "watching", "value": value])
    }

    func nextReady(_ id: String) { send(["type": "next_ready", "id": id]) }
    func nextNow() { send(["type": "next_now"]) }
    func nextCancel() { send(["type": "next_cancel"]) }

    func historyRemove(_ key: String) { send(["type": "history_remove", "key": key]) }
    func historyClear() { send(["type": "history_clear"]) }

    func isFavorite(_ item: Item) -> Bool { favorites.contains { $0.key == item.key } }
    func favRemove(_ key: String) { send(["type": "fav_remove", "key": key]) }

    /// Adds or removes a favourite.
    func toggleFavorite(_ item: Item) {
        guard item.favorite else { return }
        if isFavorite(item) { favRemove(item.key); return }
        var o: JSON = ["plugin": item.plugin, "id": item.id, "title": item.title, "live": item.live, "action": item.action]
        if let s = item.subtitle { o["subtitle"] = s }
        if let s = item.image { o["image"] = s }
        if let s = item.kind { o["kind"] = s }
        if let s = item.view { o["view"] = s }
        send(["type": "fav_add", "item": o])
    }

    /// Adds or removes a reminder for a programme.
    func toggleReminder(_ channel: Item, _ p: Program) {
        let key = reminderKey(channel.plugin, channel.id, p.start)
        if reminders.contains(where: { $0.key == key }) { reminderRemove(key); return }
        var ch: JSON = ["id": channel.id, "title": channel.title]
        if let i = channel.image { ch["image"] = i }
        var prog: JSON = ["title": p.title, "start": p.start, "end": p.end]
        if let d = p.description { prog["description"] = d }
        send(["type": "reminder_add", "plugin": channel.plugin, "channel": ch, "program": prog])
    }
    func reminderRemove(_ key: String) { send(["type": "reminder_remove", "key": key]) }
    func reminderNow() { send(["type": "reminder_now"]) }
    func reminderCancel() { send(["type": "reminder_cancel"]) }
}
