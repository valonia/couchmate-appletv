import Foundation

struct ServerInfo { let name: String; let ready: Bool }

struct ApiError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// HTTP API of the Couchmate server. Everything plugins show comes through here, already translated into the
/// TV's language by the server.
@MainActor
final class Api {
    let base: String
    let pin: String
    private let session: URLSession
    private var groupCache = [String: (Date, [Item])]()
    private var epgCache = [String: (Date, [String: [Program]])]()

    init(base: String, pin: String) {
        self.base = base
        self.pin = pin
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
    }

    /// Relative server addresses (/plugins/…, /stream/…) become absolute and carry the PIN.
    func abs(_ url: String?) -> String? {
        guard let url, !url.isEmpty else { return nil }
        if url.hasPrefix("/") { return base + url + (url.contains("?") ? "&" : "?") + "pin=" + enc(pin) }
        return url
    }

    private func call(_ path: String, body: Data? = nil, withPin: Bool = true) async throws -> Data {
        var s = base + path
        if let l = I18n.shared.lang { s += (path.contains("?") ? "&" : "?") + "lang=" + enc(l) }
        guard let url = URL(string: s) else { throw ApiError(message: tr("Invalid server address")) }
        var req = URLRequest(url: url)
        if withPin { req.setValue(pin, forHTTPHeaderField: "x-pin") }
        if let body {
            req.httpMethod = "POST"
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(code) {
            let o = parseJSON(data) as? JSON
            if o?.str("code") == "setup" { throw ApiError(message: tr("The server is not set up yet. Set a PIN code in the admin panel.")) }
            if code == 401 { throw ApiError(message: tr("Wrong PIN code")) }
            if let e = o?.str("error") { throw ApiError(message: e) }
            throw ApiError(message: tr("Server error {code}", ["code": code]))
        }
        return data
    }

    private func object(_ path: String) async throws -> JSON { (parseJSON(try await call(path)) as? JSON) ?? [:] }
    private func array(_ path: String) async throws -> [JSON] { ((parseJSON(try await call(path)) as? [Any]) ?? []).compactMap { $0 as? JSON } }

    func info() async throws -> ServerInfo {
        let o = (parseJSON(try await call("/api/info", withPin: false)) as? JSON) ?? [:]
        if o.str("app") != "Couchmate" { throw ApiError(message: tr("This is not a Couchmate server")) }
        return ServerInfo(name: o.str("name") ?? appName, ready: o.bool("ready"))
    }

    func auth() async throws { _ = try await call("/api/auth") }

    func menu() async throws -> [MenuEntry] {
        try await array("/api/menu").map { o in
            MenuEntry(core: o.str("core"), plugin: o.str("plugin"), id: o.string("id"), title: o.string("title"), icon: o.str("icon"))
        }
    }

    private func query(_ params: [String: String]) -> String {
        params.sorted { $0.key < $1.key }.map { "&" + enc($0.key) + "=" + enc($0.value) }.joined()
    }

    /// A view a plugin built from building blocks.
    func view(_ plugin: String, _ id: String, _ params: [String: String] = [:]) async throws -> JSON {
        try await object("/api/view/\(enc(plugin))/\(enc(id))?_=1" + query(params))
    }

    /// Data a view loads (any JSON: an array, an object …).
    func data(_ plugin: String, _ name: String, _ params: [String: String]) async throws -> Any? {
        let d = try await call("/api/data/\(enc(plugin))/\(enc(name))?_=1" + query(params))
        let v = parseJSON(d)
        return v is NSNull ? nil : v
    }

    /// Now and next for channels (kept for 3 minutes).
    func epg(_ plugin: String, _ ids: [String]) async throws -> [String: [Program]] {
        if ids.isEmpty { return [:] }
        let key = plugin + "/" + ids.joined(separator: ",")
        if let c = epgCache[key], Date().timeIntervalSince(c.0) < 180 { return c.1 }
        let o = try await object("/api/data/\(enc(plugin))/epg?ids=" + enc(ids.prefix(200).joined(separator: ",")))
        var out = [String: [Program]]()
        for (k, v) in o { out[k] = parsePrograms(((v as? [Any]) ?? []).compactMap { $0 as? JSON }) }
        epgCache[key] = (Date(), out)
        return out
    }

    /// The whole schedule for one channel.
    func guide(_ plugin: String, _ id: String) async throws -> [Program] {
        parsePrograms(try await array("/api/data/\(enc(plugin))/guide?id=" + enc(id)))
    }

    /// Gets an item's stream ready on the server in the background (e.g. the one focused in the queue).
    func prepare(_ plugin: String, _ id: String) async {
        _ = try? await call("/api/prepare/\(enc(plugin))?id=" + enc(id))
    }

    /// What plays next while `id` plays (the plugin's data('queue')).
    func queue(_ plugin: String, _ id: String) async throws -> Queue {
        let o = try await object("/api/data/\(enc(plugin))/queue?id=" + enc(id))
        return Queue(title: o.str("title"), current: o.str("current"), items: o.objects("items").compactMap { parseItem($0, plugin: plugin) })
    }

    func channels(_ plugin: String, _ id: String) async throws -> [Item] {
        try await array("/api/data/\(enc(plugin))/channels?id=" + enc(id)).compactMap { parseItem($0, plugin: plugin) }
    }

    /// Searches every plugin at once.
    func search(_ q: String) async throws -> [PluginResult] {
        try await array("/api/search?q=" + enc(q)).map { o in
            let plugin = o.string("plugin")
            return PluginResult(plugin: plugin, name: o.string("name"), sections: parseRows(o.objects("sections"), plugin: plugin))
        }
    }

    /// The room's shared history, newest first.
    func history() async throws -> [HistoryEntry] {
        try await array("/api/history").map { o in
            HistoryEntry(
                key: o.string("key"), plugin: o.string("plugin"), id: o.string("id"), kind: o.str("kind"), title: o.string("title"),
                subtitle: o.str("subtitle"), image: o.str("image"), live: o.bool("live"), startedBy: o.str("startedBy"),
                lastAt: o.int64("lastAt"), position: o.double("position") ?? 0, duration: o.double("duration")
            )
        }
    }

    /// The app's own texts: { english: translation } and whether everything was translated.
    func translate(_ texts: [String], lang: String) async throws -> ([String: String], Bool) {
        let body = try JSONSerialization.data(withJSONObject: ["texts": texts])
        let o = (parseJSON(try await call("/api/i18n?lang=" + enc(lang), body: body)) as? JSON) ?? [:]
        var out = [String: String]()
        for (k, v) in o.obj("translations") ?? [:] { if let s = v as? String { out[k] = s } }
        return (out, o.bool("complete"))
    }
}
