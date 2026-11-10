import SwiftUI

// =====================================================================================================
// Plugin views. A plugin describes a whole screen with building blocks (rows, columns, text, images, lists …),
// bindings ("{{item.title}}", "{{state.channel}}") and actions (play, open, set …). This file and
// ViewBlocks.swift are the only places that know how to draw them – see PLUGINS.md → Views in the server.
// =====================================================================================================

/// A plugin view to show: which plugin, which view and its parameters.
struct ViewRef: Hashable {
    let plugin: String
    let id: String
    var params: [String: String] = [:]
    var key: String { "\(plugin)/\(id)?" + params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&") }
    /// The view an item opens (action "open"): its plugin's `view` with { id }.
    static func forItem(_ item: Item) -> ViewRef { ViewRef(plugin: item.plugin, id: item.view ?? "item", params: ["id": item.id]) }
}

/// A view's state ("state" in the view, changed by "set" actions).
@MainActor
final class ViewState: ObservableObject {
    @Published private(set) var values: [String: Any] = [:]
    subscript(_ key: String) -> Any? {
        get { values[key] }
        set { values[key] = newValue }
    }
    var isEmpty: Bool { values.isEmpty }
}

/// What the app knows that views can ask about ({{item.$favorite}}, {{player.position}} …).
struct ViewEnv {
    var favorites: [String: Favorite] = [:]
    var playingKey: String? = nil
    var reminders: [String: Reminder] = [:]
    var now: Int64 = nowSec()
    /// The app's own top strip (who did what, who watches, the clock) for player overlays.
    var topbar: AnyView? = nil
}

/// Everything a building block needs while it is drawn.
@MainActor
struct ViewContext {
    let plugin: String
    let api: Api
    let sync: SyncClient
    let state: ViewState
    let roots: [String: Any]
    let env: ViewEnv
    let open: (ViewRef) -> Void
    let back: () -> Void
    var item: Any? = nil
    /// The channel a guide list belongs to (for {{item.$reminder}}).
    var channel: JSON? = nil

    func with(_ item: Any?, channel: JSON?) -> ViewContext {
        var c = self
        c.item = item
        c.channel = channel
        return c
    }
}

// MARK: - bindings

/// A string with bindings, parsed once: literal text and expressions (each a list of "a || b" alternatives).
private final class Template {
    let whole: [String]?
    let parts: [Any]
    init(whole: [String]?, parts: [Any]) { self.whole = whole; self.parts = parts }
}

private let bindRegex = try! NSRegularExpression(pattern: "\\{\\{\\s*(.+?)\\s*\\}\\}")
@MainActor private var templates = [String: Template]()

@MainActor
private func template(_ s: String) -> Template {
    if let t = templates[s] { return t }
    if templates.count > 4000 { templates.removeAll() }
    let ns = s as NSString
    let alts = { (e: String) in e.components(separatedBy: "||").map { $0.trimmingCharacters(in: .whitespaces) } }
    let matches = bindRegex.matches(in: s, range: NSRange(location: 0, length: ns.length))
    var whole: [String]? = nil
    if matches.count == 1, matches[0].range.location == 0, matches[0].range.length == ns.length {
        whole = alts(ns.substring(with: matches[0].range(at: 1)))
    }
    var parts = [Any]()
    var last = 0
    for m in matches {
        if m.range.location > last { parts.append(ns.substring(with: NSRange(location: last, length: m.range.location - last))) }
        parts.append(alts(ns.substring(with: m.range(at: 1))))
        last = m.range.location + m.range.length
    }
    if last < ns.length { parts.append(ns.substring(from: last)) }
    let t = Template(whole: whole, parts: parts)
    templates[s] = t
    return t
}

/// The expressions inside a string's bindings ("{{a}} and {{b || c}}" → ["a", "b || c"]).
func bindingExprs(_ s: String) -> [String] {
    let ns = s as NSString
    return bindRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
}

/// Text of a resolved value ("" for nothing; whole numbers without decimals).
func text(_ v: Any?) -> String {
    switch v {
    case nil: return ""
    case is NSNull: return ""
    case let s as String: return s
    case let n as NSNumber:
        if n.isBool { return n.boolValue ? "true" : "false" }
        let d = n.doubleValue
        return d.truncatingRemainder(dividingBy: 1) == 0 && abs(d) < 1e15 ? String(Int64(d)) : String(d)
    case let b as Bool: return b ? "true" : "false"
    case let i as Int: return String(i)
    case let i as Int64: return String(i)
    case let d as Double: return d.truncatingRemainder(dividingBy: 1) == 0 && abs(d) < 1e15 ? String(Int64(d)) : String(d)
    case is [Any], is JSON: return ""
    default: return "\(v!)"
    }
}

func truthy(_ v: Any?) -> Bool {
    switch v {
    case nil: return false
    case is NSNull: return false
    case let b as Bool: return b
    case let s as String: return !s.isEmpty && s != "false" && s != "0" && s != "null"
    case let n as NSNumber: return n.isBool ? n.boolValue : n.doubleValue != 0
    case let i as Int: return i != 0
    case let d as Double: return d != 0
    case let a as [Any]: return !a.isEmpty
    default: return true
    }
}

extension ViewContext {
    /// A value with its bindings filled in. A string that is only "{{path}}" keeps the value's type.
    func value(_ v: Any?) -> Any? {
        guard let s = v as? String, s.contains("{{") else { return v is NSNull ? nil : v }
        let t = template(s)
        if let whole = t.whole { return first(whole) }
        var out = ""
        for p in t.parts {
            if let lit = p as? String { out += lit } else if let alts = p as? [String] { out += text(first(alts)) }
        }
        return out
    }

    func string(_ v: Any?) -> String { text(value(v)) }

    /// The first alternative that is set.
    private func first(_ alts: [String]) -> Any? {
        for a in alts { let v = path(a); if truthy(v) { return v } }
        return nil
    }

    /// "a.b || c.d" – the first one that is set.
    func expr(_ e: String) -> Any? { first(e.components(separatedBy: "||").map { $0.trimmingCharacters(in: .whitespaces) }) }

    func path(_ p: String) -> Any? {
        if p.count >= 2, p.hasPrefix("'"), p.hasSuffix("'") { return String(p.dropFirst().dropLast()) }
        let parts = p.components(separatedBy: ".")
        var start = 1
        var cur: Any?
        switch parts[0] {
        case "item": cur = item
        case "state": start = 2; cur = parts.count > 1 ? state[parts[1]] : nil
        default: cur = roots[parts[0]]
        }
        if parts.count > start {
            for i in start..<parts.count {
                guard let next = child(cur, parts[i]) else { return nil }
                cur = next
            }
        }
        return cur
    }

    func child(_ v: Any?, _ key: String) -> Any? {
        switch v {
        case let o as JSON:
            if key.hasPrefix("$") { return computed(o, key) }
            let x = o[key]
            return x is NSNull ? nil : x
        case let a as [Any]:
            if key == "length" { return a.count }
            if let i = Int(key), i >= 0, i < a.count { return a[i] }
            return nil
        case let s as String:
            return key == "length" ? s.count : nil
        default:
            return nil
        }
    }

    /// Values the app works out for an item: $favorite, $newCount, $newLabel, $playing, $live, $now, $next, $reminder.
    func computed(_ o: JSON, _ key: String) -> Any? {
        let itemKey = "\(o.str("plugin") ?? plugin):\(o.string("id"))"
        switch key {
        case "$favorite": return env.favorites[itemKey] != nil
        case "$newCount": return env.favorites[itemKey].flatMap { $0.newCount > 0 ? $0.newCount : nil }
        case "$newLabel": return env.favorites[itemKey]?.newLabel
        case "$playing": return env.playingKey == itemKey
        case "$live":
            let s = o.int64("start"), e = o.int64("end")
            return s > 0 && env.now >= s && env.now < e
        case "$now", "$next":
            let ps = o.objects("programs")
            if key == "$now" { return ps.first { env.now >= $0.int64("start") && env.now < $0.int64("end") } }
            return ps.first { $0.int64("start") > env.now }
        case "$reminder":
            guard let ch = channel else { return nil }
            guard let r = env.reminders[reminderKey(ch.str("plugin") ?? plugin, ch.string("id"), o.int64("start"))] else { return nil }
            return r.addedBy.map { tr("Reminder · by {name}", ["name": $0]) } ?? tr("Reminder")
        default: return nil
        }
    }

    /// An object from a view as an item the app can play or favourite.
    func toItem(_ v: Any?) -> Item? { (v as? JSON).flatMap { parseItem($0, plugin: plugin) } }

    /// Parameters with their bindings filled in, as strings (for data and views).
    func params(_ o: JSON?) -> [String: String] {
        guard let o else { return [:] }
        var out = [String: String]()
        for (k, raw) in o {
            let v = value(raw)
            out[k] = (v as? JSON)?.string("id") ?? text(v)
        }
        return out
    }

    // MARK: - actions

    /// Runs an action: { play } { open, params } { set } { favorite } { remind } { if, then, else } { back }, or a list of them.
    func run(_ action: Any?) {
        if let list = action as? [Any] { for a in list { run(a) }; return }
        guard let a = action as? JSON else { return }
        if a.has("if") {
            run(truthy(value(a["if"])) ? a["then"] : a["else"])
            return
        }
        if a.has("play"), var item = toItem(value(a["play"])) {
            let sub = a.str("subtitle").map { string($0) }.flatMap { $0.isEmpty ? nil : $0 }
            if item.subtitle == nil, let sub { item.subtitle = sub }
            let pos = a["position"].flatMap { Double(text(value($0))) } ?? 0
            sync.load(item, position: pos)
        }
        if a.has("open") {
            open(ViewRef(plugin: a.str("plugin") ?? plugin, id: string(a["open"]), params: params(a.obj("params"))))
        }
        if let set = a.obj("set") { for (k, v) in set { state[k] = value(v) } }
        if a.has("favorite"), let item = toItem(value(a["favorite"])) { sync.toggleFavorite(item) }
        if let r = a.obj("remind"), let ch = toItem(value(r["channel"])), let p = value(r["program"]) as? JSON {
            sync.toggleReminder(ch, Program(title: p.string("title"), description: p.str("description"), start: p.int64("start"), end: p.int64("end")))
        }
        if a.bool("back") { back() }
    }

    /// Whether a block shows ("when" / "unless").
    func visible(_ node: JSON) -> Bool {
        func all(_ v: Any?) -> Bool { (v as? [Any]).map { $0.allSatisfy { truthy(value($0)) } } ?? truthy(value(v)) }
        func any(_ v: Any?) -> Bool { (v as? [Any]).map { $0.contains { truthy(value($0)) } } ?? truthy(value(v)) }
        if node.has("when") && !all(node["when"]) { return false }
        if node.has("unless") && any(node["unless"]) { return false }
        return true
    }
}

// MARK: - tokens

func colorOf(_ v: String?, _ fallback: Color = Palette.text) -> Color {
    switch v {
    case nil, "": return fallback
    case "text": return Palette.text
    case "textSoft": return Color(hex: 0xCCFFFFFF)
    case "dim": return Palette.dim
    case "faint": return Palette.faint
    case "accent": return Palette.accent
    case "gold": return Palette.gold
    case "live": return Palette.live
    case "green": return Palette.green
    case "status": return Palette.status
    case "white": return .white
    case "black": return .black
    case "dark": return Color(hex: 0xB30A0C10)
    case "track": return Color(hex: 0x33FFFFFF)
    case "trackSoft": return Color(hex: 0x22FFFFFF)
    default: return Color(css: v!) ?? fallback
    }
}

/// A block's background: a colour or one of the named gradients.
@ViewBuilder
func backgroundOf(_ v: String?, corner: CGFloat) -> some View {
    let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
    switch v {
    case nil, "", "none": EmptyView()
    case "panel": shape.fill(Palette.panel)
    case "panelHi": shape.fill(Palette.panelHi)
    case "bg": shape.fill(Palette.bg)
    case "accentSoft": shape.fill(Palette.accentSoft)
    case "heroFade": shape.fill(LinearGradient(stops: [.init(color: Palette.panel, location: 0.35), .init(color: Palette.panel.opacity(0.55), location: 0.75), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
    case "bottomFade": shape.fill(LinearGradient(colors: [.clear, Color(hex: 0xF00A0C10)], startPoint: .top, endPoint: .bottom))
    case "topFade": shape.fill(LinearGradient(colors: [Color(hex: 0xD9000000), .clear], startPoint: .top, endPoint: .bottom))
    case "sideFade": shape.fill(LinearGradient(colors: [Color(hex: 0xF50A0C10), Color(hex: 0xE60A0C10)], startPoint: .leading, endPoint: .trailing))
    default: shape.fill(colorOf(v))
    }
}

func alignOf(_ v: String?) -> Alignment {
    switch v {
    case "topStart": return .topLeading
    case "topCenter": return .top
    case "topEnd": return .topTrailing
    case "centerStart": return .leading
    case "centerEnd": return .trailing
    case "bottomStart": return .bottomLeading
    case "bottomCenter": return .bottom
    case "bottomEnd": return .bottomTrailing
    default: return .center
    }
}

/// Padding: a number, [horizontal, vertical] or [start, top, end, bottom] – in dp.
func paddingOf(_ v: Any?) -> EdgeInsets? {
    if let n = v as? NSNumber, !n.isBool { let x = CGFloat(n.doubleValue).dp; return EdgeInsets(top: x, leading: x, bottom: x, trailing: x) }
    guard let a = v as? [Any] else { return nil }
    let d = a.map { CGFloat(($0 as? NSNumber)?.doubleValue ?? 0).dp }
    switch d.count {
    case 2: return EdgeInsets(top: d[1], leading: d[0], bottom: d[1], trailing: d[0])
    case 4: return EdgeInsets(top: d[1], leading: d[0], bottom: d[3], trailing: d[2])
    default: return nil
    }
}

func dpOf(_ v: Any?) -> CGFloat? {
    guard let n = v as? NSNumber, !n.isBool else { return nil }
    return CGFloat(n.doubleValue).dp
}

/// Text styles: size, weight and colour.
struct TextStyleSpec { let size: Double; let weight: Font.Weight; let color: Color?; var upper = false; var spacing: CGFloat = 0 }

func styleOf(_ name: String?) -> TextStyleSpec {
    switch name {
    case "title": return TextStyleSpec(size: 28, weight: .bold, color: nil)
    case "headline": return TextStyleSpec(size: 21, weight: .bold, color: nil)
    case "bodyStrong": return TextStyleSpec(size: 17, weight: .medium, color: nil)
    case "caption": return TextStyleSpec(size: 14, weight: .regular, color: Color(hex: 0xB3FFFFFF))
    case "dim": return TextStyleSpec(size: 15, weight: .regular, color: Palette.dim)
    case "faint": return TextStyleSpec(size: 14, weight: .regular, color: Palette.faint)
    case "soft": return TextStyleSpec(size: 15, weight: .regular, color: nil)
    case "label": return TextStyleSpec(size: 12, weight: .bold, color: Palette.faint, upper: true, spacing: 1.5)
    default: return TextStyleSpec(size: 16, weight: .regular, color: nil)
    }
}

func weightOf(_ node: JSON) -> Double? { node.double("weight").flatMap { $0 > 0 ? $0 : nil } }

func childrenOf(_ node: JSON) -> [JSON] { node.objects("children") }

func toList(_ v: Any?) -> [Any] { (v as? [Any]) ?? [] }
