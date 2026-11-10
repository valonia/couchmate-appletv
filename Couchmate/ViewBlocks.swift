import SwiftUI

// The second half of the view renderer: drawing the blocks, lists and the screens.

/// How a block is placed by its parent: weighted children fill what is left in a row or column.
enum Fill { case none, width, height }

// MARK: - data

/// Loads a block's data ({ name, params, delay, refresh }); loads again when the filled-in params change.
@MainActor
final class DataLoader: ObservableObject {
    @Published var value: Any?
    @Published var error: String?
    @Published var loadedKey: String?

    func run(_ ctx: ViewContext, name: String, params: [String: String], key: String, delayMs: Int64, refresh: Int64) async {
        if delayMs > 0 { try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000) }
        while !Task.isCancelled {
            do {
                value = try await ctx.api.data(ctx.plugin, name, params)
                error = nil
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            loadedKey = key
            if refresh <= 0 { break }
            try? await Task.sleep(nanoseconds: UInt64(refresh) * 1_000_000_000)
        }
    }
}

private func dataKey(_ ctx: ViewContext, _ spec: JSON) -> (String, [String: String]) {
    let params = ctx.params(spec.obj("params"))
    return (spec.string("name") + "|" + params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&"), params)
}

// MARK: - one block

/// Draws one building block.
struct BlockView: View {
    let ctx: ViewContext
    let node: JSON
    var fill: Fill = .none
    @ObservedObject private var state: ViewState

    init(_ ctx: ViewContext, _ node: JSON, fill: Fill = .none) {
        self.ctx = ctx
        self.node = node
        self.fill = fill
        self._state = ObservedObject(wrappedValue: ctx.state)
    }

    var body: some View {
        if ctx.visible(node) {
            let type = node.string("type")
            if let spec = node.obj("data"), type != "list", type != "grid" {
                DataBlock(ctx: ctx, node: node, spec: spec, fill: fill)
            } else {
                drawBlock(ctx, node, fill: fill)
            }
        }
    }
}

/// A block with its own data: drawn with the data as {{item}} once it has loaded.
private struct DataBlock: View {
    let ctx: ViewContext
    let node: JSON
    let spec: JSON
    let fill: Fill
    @StateObject var loader = DataLoader()

    var body: some View {
        let (key, params) = dataKey(ctx, spec)
        Group {
            if loader.loadedKey == key, let v = loader.value {
                drawBlock(ctx.with(v, channel: ctx.channel), node, fill: fill)
            } else if loader.value == nil, let e = loader.error {
                Message(text: tr("Error: {message}", ["message": e]), error: true)
            } else {
                Message(text: node.str("loading") ?? tr("Loading…"))
            }
        }
        .task(id: key) {
            await loader.run(ctx, name: spec.string("name"), params: params, key: key, delayMs: spec.int64("delay"), refresh: spec.int64("refresh"))
        }
    }
}

@MainActor
func drawBlock(_ ctx: ViewContext, _ node: JSON, fill: Fill) -> AnyView {
    let type = node.string("type")
    let gap = dpOf(node["gap"]) ?? 0
    var view: AnyView
    var skipPadding = false
    switch type {
    case "row":
        let align: VerticalAlignment = node.str("align") == "center" ? .center : node.str("align") == "bottom" ? .bottom : .top
        view = AnyView(HStack(alignment: align, spacing: gap) {
            ForEach(Array(childrenOf(node).enumerated()), id: \.offset) { _, c in
                BlockView(ctx, c, fill: weightOf(c) != nil ? .width : .none)
            }
        })
    case "column":
        let align: HorizontalAlignment = node.str("align") == "center" ? .center : node.str("align") == "end" ? .trailing : .leading
        view = AnyView(VStack(alignment: align, spacing: gap) {
            ForEach(Array(childrenOf(node).enumerated()), id: \.offset) { _, c in
                BlockView(ctx, c, fill: weightOf(c) != nil ? .height : .none)
            }
        })
    case "box":
        view = AnyView(ZStack(alignment: .topLeading) {
            ForEach(Array(childrenOf(node).enumerated()), id: \.offset) { _, c in
                if c.has("align") {
                    BlockView(ctx, c).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignOf(c.str("align")))
                } else {
                    BlockView(ctx, c)
                }
            }
        })
    case "spacer":
        view = AnyView(Color.clear.frame(width: dpOf(node["width"]) ?? 0, height: dpOf(node["height"]) ?? 0))
        if node.has("weight") { view = AnyView(Spacer(minLength: 0)) }
    case "text":
        view = AnyView(TextBlock(ctx: ctx, node: node))
    case "time":
        view = AnyView(TimeBlock(ctx: ctx, node: node))
    case "image":
        let url = ctx.api.abs(ctx.string(node["src"]).nilIfEmpty)
        view = AnyView(Thumb(url: url, fallback: ctx.string(node["fallback"]), fit: node.str("fit") == "contain", corner: CGFloat(node.double("radius") ?? 6)))
    case "icon":
        let path = node.str("name").flatMap { AppIcon.named($0) } ?? node.str("path")
        let color = ctx.string(node["color"]).nilIfEmpty
        view = AnyView(PathIcon(path: path, size: CGFloat(node.double("size") ?? 24)).foregroundStyle(color.map { colorOf($0) } ?? Palette.text))
    case "badge":
        let t = ctx.string(node["text"])
        if t.isEmpty { return AnyView(EmptyView()) }
        skipPadding = true
        let pad = paddingOf(node["padding"]) ?? EdgeInsets()
        view = AnyView(Text(t).font(font(node.double("size") ?? 11, .bold))
            .foregroundStyle(colorOf(ctx.string(node["textColor"]).nilIfEmpty, .white))
            .padding(.horizontal, 6.dp).padding(.vertical, 1.dp)
            .background(RoundedRectangle(cornerRadius: 4.dp).fill(colorOf(ctx.string(node["color"]).nilIfEmpty, Palette.live)))
            .padding(pad))
    case "progress":
        let start = Int64(text(ctx.value(node["start"])))
        let end = Int64(text(ctx.value(node["end"])))
        var fraction = Double(text(ctx.value(node["value"]))) ?? 0
        if let s = start, let e = end, e > s { fraction = Double(ctx.env.now - s) / Double(e - s) }
        view = AnyView(ProgressLine(fraction: fraction, color: colorOf(ctx.string(node["color"]).nilIfEmpty, Palette.accent), track: colorOf(ctx.string(node["track"]).nilIfEmpty, Color(hex: 0x33FFFFFF)))
            .frame(maxWidth: node.has("width") ? nil : .infinity))
    case "clock":
        view = AnyView(ClockView(size: node.double("size") ?? 22))
    case "topbar":
        return ctx.env.topbar ?? AnyView(EmptyView())
    case "button":
        view = AnyView(Pill(text: ctx.string(node["text"]), selected: truthy(ctx.value(node["selected"]))) { ctx.run(node["onClick"]) })
    case "list", "grid":
        view = AnyView(ListBlock(ctx: ctx, node: node, grid: type == "grid"))
        skipPadding = true
    default:
        return AnyView(EmptyView())
    }
    return applyBase(view, ctx, node, fill: fill, skipPadding: skipPadding)
}

/// Size, background, corners and padding that any block can have.
@MainActor
private func applyBase(_ content: AnyView, _ ctx: ViewContext, _ node: JSON, fill: Fill, skipPadding: Bool) -> AnyView {
    var v = content
    if !skipPadding, let p = paddingOf(node["padding"]) { v = AnyView(v.padding(p)) }
    let listLike = node.str("type") == "list" || node.str("type") == "grid"
    // width
    if let w = dpOf(node["width"]) { v = AnyView(v.frame(width: w)) }
    else if let w = node.str("width") {
        if w == "fill" { v = AnyView(v.frame(maxWidth: .infinity, alignment: .leading)) }
        else if w.hasSuffix("%"), let pct = Double(w.dropLast()) { v = AnyView(v.containerRelativeFrame(.horizontal, alignment: .leading) { len, _ in len * pct / 100 }) }
    } else if listLike { v = AnyView(v.frame(maxWidth: .infinity, alignment: .leading)) }
    // height
    if let h = dpOf(node["height"]) { v = AnyView(v.frame(height: h)) }
    else if let h = node.str("height") {
        if h == "fill" { v = AnyView(v.frame(maxHeight: .infinity, alignment: .top)) }
        else if h.hasSuffix("%"), let pct = Double(h.dropLast()) { v = AnyView(v.containerRelativeFrame(.vertical, alignment: .top) { len, _ in len * pct / 100 }) }
    }
    // weight from the parent
    switch fill {
    case .width: v = AnyView(v.frame(maxWidth: .infinity, alignment: .leading))
    case .height: v = AnyView(v.frame(maxHeight: .infinity, alignment: .top))
    case .none: break
    }
    // On lists and grids "aspect" is the shape of each item, not of the list.
    if !listLike, let a = node.double("aspect"), a > 0 { v = AnyView(v.aspectRatio(CGFloat(a), contentMode: .fit)) }
    let corner = dpOf(node["radius"]) ?? 0
    if let bg = ctx.string(node["background"]).nilIfEmpty { v = AnyView(v.background(backgroundOf(bg, corner: corner))) }
    if node.has("radius") { v = AnyView(v.clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))) }
    if let o = node.double("opacity") { v = AnyView(v.opacity(o)) }
    return v
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - text

/// Text: "text", or "join" (parts with an empty binding are left out) with a "separator".
private struct TextBlock: View {
    let ctx: ViewContext
    let node: JSON
    var body: some View {
        var content: String
        if let parts = node.arr("join") {
            content = parts.compactMap { p -> String? in
                if let s = p as? String {
                    let exprs = bindingExprs(s)
                    if !exprs.isEmpty && exprs.contains(where: { text(ctx.expr($0)).isEmpty }) { return nil }
                    let v = ctx.string(s)
                    return v.trimmingCharacters(in: .whitespaces).isEmpty ? nil : v
                }
                // A translated text from the plugin (already a string from the server) or a number.
                let v = text(p)
                return v.isEmpty ? nil : v
            }.joined(separator: node.str("separator") ?? "  ·  ")
        } else {
            content = ctx.string(node["text"])
        }
        if content.isEmpty { content = ctx.string(node["fallback"]) }
        return StyledText(ctx: ctx, node: node, text: content)
    }
}

/// A time: "time" (21:30, default), "day" (Today, Tomorrow, Tuesday 10 November) or "datetime".
private struct TimeBlock: View {
    let ctx: ViewContext
    let node: JSON
    var body: some View {
        if let sec = Double(text(ctx.value(node["value"]))) {
            let s = Int64(sec)
            let t: String = {
                switch node.str("format") {
                case "day": return dayLabel(s)
                case "datetime": return "\(dayLabel(s)) \(hhmm(s))"
                default: return hhmm(s)
                }
            }()
            StyledText(ctx: ctx, node: node, text: t)
        }
    }
}

struct StyledText: View {
    let ctx: ViewContext
    let node: JSON
    let text: String
    var body: some View {
        if !text.isEmpty {
            let styleName = node.str("style")
            let st = styleOf(styleName)
            let explicit = ctx.string(node["color"]).nilIfEmpty
            let size = node.double("size") ?? st.size
            let base = Text(st.upper ? text.uppercased() : text)
                .font(font(size, node.bool("bold") ? .bold : st.weight))
                .tracking(st.spacing.dp)
            let lines = node.int("maxLines")
            Group {
                if let explicit { base.foregroundStyle(colorOf(explicit)) }
                else if let c = st.color { base.foregroundStyle(c) }
                else if styleName == "soft" { base.opacity(0.7) }
                else { base }
            }
            .lineLimit(lines)
        }
    }
}

// MARK: - lists and grids

private struct Entry: Identifiable {
    let id: String
    let index: Int
    let value: Any
    var heading: String? = nil
}

/// A list or grid of items. Items come from "items" (a binding) or "data" (an array, or an object with "items").
/// focus: row | card | poster | pill | none – how an item looks and is focused. Actions: onFocus, onClick, onLongClick.
struct ListBlock: View {
    let ctx: ViewContext
    let node: JSON
    let grid: Bool
    @StateObject var loader = DataLoader()
    @StateObject var enrichLoader = DataLoader()

    var body: some View {
        let spec = node.obj("data")
        let raw: Any? = spec != nil ? ((loader.value as? JSON)?["items"] ?? loader.value) : ctx.value(node["items"])
        let items = toList(raw)
        let shown = merged(items)
        let dataKeyValue = spec.map { dataKey(ctx, $0) }
        Group {
            if spec != nil && loader.value == nil && loader.error != nil {
                Message(text: tr("Error: {message}", ["message": loader.error ?? ""]), error: true)
            } else if spec != nil && loader.loadedKey == nil {
                Message(text: node.str("loading") ?? tr("Loading…"))
            } else if shown.isEmpty {
                if let e = node.str("empty") { Message(text: ctx.string(e)) } else { Color.clear.frame(height: 1) }
            } else {
                content(shown)
            }
        }
        .task(id: dataKeyValue?.0 ?? "") {
            guard let spec, let dk = dataKeyValue else { return }
            await loader.run(ctx, name: spec.string("name"), params: dk.1, key: dk.0, delayMs: spec.int64("delay"), refresh: spec.int64("refresh"))
        }
        .task(id: enrichKey(items)) {
            guard let e = node.obj("enrich") else { return }
            let ids = items.compactMap { ($0 as? JSON)?.str("id") }.prefix(200)
            if ids.isEmpty { return }
            var params = ctx.params(e.obj("params"))
            params["ids"] = ids.joined(separator: ",")
            await enrichLoader.run(ctx, name: e.string("name"), params: params, key: "enrich", delayMs: 0, refresh: e.int64("refresh"))
        }
    }

    private func enrichKey(_ items: [Any]) -> String {
        guard node.has("enrich") else { return "" }
        return items.compactMap { ($0 as? JSON)?.str("id") }.prefix(200).joined(separator: ",")
    }

    /// Extra data for the items ({ name, as }), fetched with ?ids=… and merged into each item.
    private func merged(_ items: [Any]) -> [Any] {
        guard let e = node.obj("enrich"), let extra = enrichLoader.value as? JSON else { return items }
        let name = e.str("as") ?? "extra"
        return items.map { o in
            guard var obj = o as? JSON, let add = extra[obj.string("id")] else { return o }
            obj[name] = add
            return obj
        }
    }

    @ViewBuilder
    private func content(_ shown: [Any]) -> some View {
        let gap = dpOf(node["gap"]) ?? 2.dp
        let pad = paddingOf(node["padding"]) ?? EdgeInsets()
        let entries = makeEntries(shown)
        if grid {
            let minWidth = dpOf(node["minWidth"]) ?? 120.dp
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: gap, alignment: .top)], alignment: .leading, spacing: dpOf(node["rowGap"]) ?? 16.dp) {
                    ForEach(entries) { e in item(e) }
                }
                .padding(pad)
            }
            .scrollClipDisabled()
        } else if node.str("direction") == "horizontal" {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: gap) {
                    ForEach(entries) { e in item(e) }
                }
                .padding(pad)
            }
            .scrollClipDisabled()
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: gap) {
                    ForEach(entries) { e in
                        if let h = e.heading {
                            Text(h.uppercased()).font(font(12, .bold)).tracking(1.dp).foregroundStyle(Palette.faint)
                                .padding(.leading, 6.dp).padding(.top, 10.dp).padding(.bottom, 4.dp)
                        } else {
                            item(e)
                        }
                    }
                }
                .padding(pad)
            }
            .scrollClipDisabled()
        }
    }

    /// Stable ids (the item's id, or its place if ids repeat or are missing), and day headings ("sectionBy": "day").
    private func makeEntries(_ shown: [Any]) -> [Entry] {
        var seen = Set<String>()
        var out = [Entry]()
        var lastDay: String? = nil
        let byDay = node.str("sectionBy") == "day"
        for (i, o) in shown.enumerated() {
            if byDay, let start = (o as? JSON)?.int64("start"), start > 0 {
                let d = dayLabel(start)
                if d != lastDay { out.append(Entry(id: "h:\(d):\(i)", index: -1, value: d, heading: d)); lastDay = d }
            }
            let id = (o as? JSON)?.string("id") ?? ""
            out.append(Entry(id: !id.isEmpty && seen.insert(id).inserted ? id : "#\(i)", index: i, value: o))
        }
        return out
    }

    private func item(_ e: Entry) -> some View {
        let channel = ctx.value(node["channel"]) as? JSON
        let c = ctx.with(e.value, channel: channel)
        let selectedId = ctx.string(node["selected"]).nilIfEmpty
        let selected = selectedId != nil && (e.value as? JSON)?.string("id") == selectedId
        return ItemBox(
            ctx: c, node: node, template: node.obj("item") ?? [:], style: node.str("focus") ?? "row", selected: selected,
            onFocus: { if node.has("onFocus") { c.run(node["onFocus"]) } },
            onClick: { c.run(node["onClick"]) },
            onLongPress: node.has("onLongClick") ? { c.run(node["onLongClick"]) } : nil
        )
    }
}

/// One item, drawn and focused the way the list's "focus" says.
private struct ItemBox: View {
    let ctx: ViewContext
    let node: JSON
    let template: JSON
    let style: String
    let selected: Bool
    let onFocus: () -> Void
    let onClick: () -> Void
    let onLongPress: (() -> Void)?
    @FocusState private var focused: Bool

    var body: some View {
        let width = dpOf(node["itemWidth"])
        let height = dpOf(node["itemHeight"])
        switch style {
        case "row":
            button(.row) {
                BlockView(ctx, template, fill: .width)
                    .padding(.horizontal, 14.dp)
                    .frame(maxWidth: .infinity, minHeight: height ?? 56.dp, maxHeight: height ?? 56.dp, alignment: .leading)
            }
        case "card":
            button(.card) {
                BlockView(ctx, template)
                    .frame(width: width, height: height, alignment: .topLeading)
            }
        case "poster":
            VStack(alignment: .leading, spacing: 0) {
                button(.poster) {
                    BlockView(ctx, template)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .aspectRatio(CGFloat(node.double("aspect") ?? 2.0 / 3.0), contentMode: .fit)
                }
                if let sub = ctx.string(node["sublabel"]).nilIfEmpty {
                    Text(sub).font(font(12, .semibold)).foregroundStyle(Palette.accent).lineLimit(1).padding(.top, 6.dp).padding(.leading, 2.dp)
                }
                if let label = ctx.string(node["label"]).nilIfEmpty {
                    Text(cleanTitle(label)).font(font(13)).foregroundStyle(Palette.dim).lineLimit(1).padding(.top, 6.dp).padding(.horizontal, 2.dp)
                }
            }
            .frame(width: width)
        case "pill":
            button(.pill) {
                BlockView(ctx, template).padding(.horizontal, 14.dp).padding(.vertical, 8.dp)
            }
        default:
            BlockView(ctx, template).frame(width: width)
        }
    }

    private func button<L: View>(_ look: FocusLook, @ViewBuilder label: () -> L) -> some View {
        let content = label()
        return Button(action: onClick) { content.contentShape(Rectangle()) }
            .buttonStyle(FocusStyle(look: look, selected: selected))
            .focused($focused)
            .onChange(of: focused) { _, f in if f { onFocus() } }
            .onLongPress(onLongPress)
    }
}

// MARK: - screens

/// The latest answer for the last views shown (in memory only).
@MainActor private var viewCache = [String: JSON]()

@MainActor
func makeEnv(_ sync: SyncClient, topbar: AnyView? = nil) -> ViewEnv {
    var favs = [String: Favorite]()
    for f in sync.favorites { favs[f.key] = f }
    var rems = [String: Reminder]()
    for r in sync.reminders { rems[r.key] = r }
    return ViewEnv(favorites: favs, playingKey: sync.state?.media?.key, reminders: rems, now: nowSec(), topbar: topbar)
}

/// One plugin view: loaded from the server, with its own state ("state" in the view, changed by "set" actions).
struct ViewScreen: View {
    @ObservedObject var sync: SyncClient
    let api: Api
    let ref: ViewRef
    let open: (ViewRef) -> Void
    let back: () -> Void
    @StateObject var state = ViewState()
    @State var root: JSON?
    @State var error: String?
    @State var initialized = false

    var body: some View {
        Group {
            if let r = root {
                let viewRoot = mergedRoot(r)
                // Redrawn every half minute, so programme progress and "on now" stay right.
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    BlockView(ViewContext(plugin: ref.plugin, api: api, sync: sync, state: state, roots: ["view": viewRoot], env: makeEnv(sync), open: open, back: back), r)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else if let error {
                Message(text: tr("Error: {message}", ["message": error]), error: true)
            } else {
                Message(text: tr("Loading…"))
            }
        }
        .task(id: "\(ref.key)|\(sync.textsVersion)|\(I18n.shared.lang ?? "")") { await load() }
    }

    private func mergedRoot(_ r: JSON) -> JSON {
        var v = r.obj("view") ?? [:]
        for (k, p) in ref.params where v[k] == nil { v[k] = p }
        return v
    }

    private func load() async {
        let cacheKey = "\(I18n.shared.lang ?? "")|\(ref.key)"
        if root == nil, let cached = viewCache[cacheKey] { root = cached }
        while !Task.isCancelled {
            do {
                let v = try await api.view(ref.plugin, ref.id, ref.params)
                if !initialized && state.isEmpty, let s = v.obj("state") {
                    for (k, val) in s { state[k] = val is NSNull ? nil : val }
                }
                initialized = true
                root = v
                viewCache[cacheKey] = v
                error = nil
            } catch {
                if Task.isCancelled { return }
                self.error = error.localizedDescription
            }
            let refresh = root?.int64("refresh") ?? 0
            if refresh <= 0 { return }
            try? await Task.sleep(nanoseconds: UInt64(refresh) * 1_000_000_000)
        }
    }
}

/// A stack of plugin views starting at `root`: "open" pushes a view, Back (Menu on the remote) pops it.
/// At the root, Back calls `onExit` (if given) – otherwise the screen around it handles Back.
struct ViewHost: View {
    @ObservedObject var sync: SyncClient
    let api: Api
    let root: ViewRef
    var onExit: (() -> Void)? = nil
    @State var stack: [ViewRef] = []

    var body: some View {
        let current = stack.last ?? root
        ViewScreen(sync: sync, api: api, ref: current, open: { stack.append($0) }, back: { goBack() })
            .id(current.key + "#\(stack.count)")
            .onExitCommand(perform: (!stack.isEmpty || onExit != nil) ? { goBack() } : nil)
    }

    private func goBack() {
        if !stack.isEmpty { stack.removeLast() } else { onExit?() }
    }
}

/// A plugin's overlay on top of the video, bound to {{media}} and {{player}} and the app's top strip ("topbar").
struct PluginOverlay: View {
    @ObservedObject var sync: SyncClient
    let api: Api
    let plugin: String
    let node: JSON
    let media: JSON
    let player: JSON
    let topbar: AnyView
    @StateObject var state = ViewState()

    var body: some View {
        let ctx = ViewContext(plugin: plugin, api: api, sync: sync, state: state, roots: ["media": media, "player": player], env: makeEnv(sync, topbar: topbar), open: { _ in }, back: {})
        BlockView(ctx, node).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
