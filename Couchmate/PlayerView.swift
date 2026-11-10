import SwiftUI
import TVVLCKit

/// The VLC picture.
struct VideoSurface: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// The player. Everything plays in sync for the whole room (PlaybackSync). What the remote's buttons do, what is
/// in the settings panel and which overlay shows are decided by the plugin (media.player).
struct PlayerView: View {
    @ObservedObject var sync: SyncClient
    let api: Api
    let onExit: () -> Void
    @StateObject var controller = PlaybackSync()
    @State var now = Date()
    @State var overlayUntil = Date().addingTimeInterval(6)
    @State var showChat = Prefs.shared.chatOn
    @State var optVersion = 0
    @State var channels: [Item] = []
    @State var epg: [String: [Program]] = [:]
    @State var pendingSeek: Double?
    @State var seekTask: Task<Void, Never>?
    @State var panelOpen = false
    @State var settingsPanel = false
    @State var queueOpen = false
    @State var queue: Queue?
    @State var starting: Item?
    @State var startingFrom = 0

    private var media: Media? { sync.state?.media }
    private var spec: PlayerSpec { media?.player ?? defaultSpec(media) }
    private var chatVisible: Bool { media?.chat == true && showChat }
    private var anyPanel: Bool { panelOpen || settingsPanel || queueOpen }
    private var chatWidth: CGFloat { queueOpen ? 460.dp : chatVisible ? 400.dp : 0 }

    var body: some View {
        let st = sync.state
        let showOverlay = !anyPanel && (now < overlayUntil || st?.paused == true || pendingSeek != nil)
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            // The video – a button so the remote's centre press is OK; moves and play/pause go to the plugin's keys.
            Button(action: { pressOK() }) {
                VideoSurface(view: controller.videoView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.trailing, chatWidth)
            }
            .buttonStyle(FocusStyle(look: .plain))
            .disabled(anyPanel)
            .onMoveCommand { dir in move(dir) }
            .onPlayPauseCommand { sync.toggle(); poke() }
            .ignoresSafeArea()

            // The column to the right of the video: the queue while it is open, otherwise the chat.
            if queueOpen, let q = queue {
                QueuePanel(queue: q, api: api) { item in
                    sync.load(item)
                    startingFrom = sync.state?.version ?? 0
                    starting = item
                    queueOpen = false
                }
                .frame(width: chatWidth).frame(maxHeight: .infinity)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .ignoresSafeArea()
            } else if chatVisible {
                ChatPanel(messages: sync.chat)
                    .frame(width: chatWidth).frame(maxHeight: .infinity)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .ignoresSafeArea()
            }

            // Picked in the queue: say so right away, until it plays.
            if let pick = starting, !panelOpen {
                StatusChip(text: tr("Starting “{title}”…", ["title": pick.title]))
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 28.dp).padding(.trailing, 28.dp + chatWidth)
            } else if !showOverlay, !panelOpen, !controller.status.isEmpty {
                StatusChip(text: controller.status)
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 28.dp).padding(.trailing, 28.dp + chatWidth)
            }

            if showOverlay, let st, let m = media {
                overlay(st, m).padding(.trailing, chatWidth).transition(.opacity).allowsHitTesting(false)
            }

            if panelOpen {
                ChannelPanel(title: media?.subtitle ?? tr("Channels"), channels: channels, epg: epg, currentKey: media?.key, api: api,
                             onPick: { loadChannel($0); panelOpen = false }, onClose: { panelOpen = false })
                    .transition(.move(edge: .leading))
            }
            if settingsPanel {
                SettingsPanel(sections: settingsSections(), onClose: { settingsPanel = false })
                    .transition(.move(edge: .trailing))
            }

            // A reminder: the channel switches for everyone soon.
            if let r = st?.reminder, !anyPanel {
                ReminderCard(reminder: r, secondsLeft: max(0, (r.switchAt - sync.serverNow() + 999) / 1000), interactive: false, onNow: {}, onCancel: {})
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(48.dp)
            }
            // "Next" (an episode that ended, or a song about to end).
            if let u = st?.upNext, !anyPanel {
                UpNextCard(upNext: u, secondsLeft: max(0, Double(u.startsAt - sync.serverNow()) / 1000), api: api)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(48.dp)
            }
            NoticeToast(sync: sync).frame(maxWidth: .infinity, alignment: .top).padding(.top, 24.dp).allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.2), value: showOverlay)
        .animation(.easeOut(duration: 0.2), value: anyPanel)
        .onExitCommand { back() }
        .onAppear {
            sync.setWatching(true)
            controller.urlFor = { m in urlFor(m) }
        }
        .onDisappear {
            sync.setWatching(false)
            sync.setChat(false)
            controller.shutdown()
        }
        // The sync loop (+ a position report every other second) and a clock for the UI.
        .task {
            var n = 0
            while !Task.isCancelled {
                controller.tick(sync.state, sync: sync)
                n += 1
                if n % 8 == 0 { sync.report(controller.positionSec, status: controller.status) }
                if n % 2 == 0 { now = Date() }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        .onChange(of: sync.state?.version) { _, _ in
            if let a = sync.state?.action, ["load", "play", "pause", "seek"].contains(a) { poke() }
            // What was picked in the queue: until it plays (or something else was started).
            if let s = starting, let st = sync.state {
                if let m = st.media, m.key != s.key, st.action == "load", st.version > startingFrom { starting = nil }
                if st.media?.key == s.key && !st.paused && !st.waiting { starting = nil }
            }
        }
        .onChange(of: chatVisible, initial: true) { _, v in sync.setChat(v) }
        .task(id: "\(media?.key ?? "")|\(spec.channels)") { await loadChannels() }
        .task(id: "\(media?.key ?? "")|\(spec.guide)|\(channels.count)") { await loadEpg() }
        .task(id: "\(media?.key ?? "")|\(spec.queue)") { await loadQueue() }
        .task(id: starting?.key ?? "") {
            guard starting != nil else { return }
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            starting = nil
        }
    }

    // MARK: - keys

    private func poke() { overlayUntil = Date().addingTimeInterval(6); now = Date() }

    private func pressOK() {
        let cur = sync.state
        if cur?.reminder != nil { sync.reminderNow(); return } // OK = switch channel now
        if cur?.upNext != nil { sync.nextNow(); return } // OK = play the next one now
        perform(spec.keys["ok"] ?? "pause")
    }

    private func move(_ dir: MoveCommandDirection) {
        switch dir {
        case .up: perform(spec.keys["up"] ?? "info")
        case .down: perform(spec.keys["down"] ?? "settings")
        case .left: perform(spec.keys["left"] ?? "none")
        case .right: perform(spec.keys["right"] ?? "settings")
        @unknown default: break
        }
    }

    private func back() {
        if settingsPanel { settingsPanel = false }
        else if panelOpen { panelOpen = false }
        else if queueOpen { queueOpen = false }
        else if sync.state?.reminder != nil { sync.reminderCancel() } // Menu cancels the reminder for everyone
        else if sync.state?.upNext != nil { sync.nextCancel() } // Menu cancels "next" for everyone
        else { onExit() }
    }

    /// What a key does, as the plugin decided.
    private func perform(_ action: String) {
        switch action {
        case "pause": sync.toggle(); poke()
        case "settings": settingsPanel = true
        case "chat": if media?.chat == true { toggleChat() } else { poke() }
        case "channels": if !channels.isEmpty { panelOpen = true } else { poke() }
        case "channel_up": zap(-1)
        case "channel_down": zap(1)
        case "seek_back": nudge(-10)
        case "seek_forward": nudge(10)
        case "queue":
            // Fetched again on every press – the plugin may have something new. Nothing queued: the overlay.
            if !(queue?.items.isEmpty ?? true) { queueOpen = true }
            if let m = media, spec.queue {
                Task {
                    if let fresh = try? await api.queue(m.plugin, m.id), sync.state?.media?.key == m.key { queue = fresh }
                    if queue?.items.isEmpty ?? true { queueOpen = false; poke() } else { queueOpen = true }
                }
            } else if queue?.items.isEmpty ?? true { poke() }
        default: poke()
        }
    }

    private func toggleChat() { showChat.toggle(); Prefs.shared.chatOn = showChat }

    /// Seeking: gather presses and send ONE seek after a short pause.
    private func nudge(_ delta: Double) {
        guard let m = sync.state?.media, !m.live else { return }
        let dur = controller.durationSec
        let start = pendingSeek ?? controller.positionSec
        pendingSeek = min(max(0, start + delta), dur > 0 ? dur - 1 : .greatestFiniteMagnitude)
        poke()
        seekTask?.cancel()
        seekTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            if Task.isCancelled { return }
            if let p = pendingSeek { sync.seek(p) }
            try? await Task.sleep(nanoseconds: 600_000_000)
            if !Task.isCancelled { pendingSeek = nil }
        }
    }

    private func loadChannel(_ item: Item) {
        var i = item
        if i.subtitle == nil { i.subtitle = sync.state?.media?.subtitle }
        sync.load(i)
    }

    private func zap(_ dir: Int) {
        guard let m = sync.state?.media, channels.count >= 2, let i = channels.firstIndex(where: { $0.key == m.key }) else { return }
        loadChannel(channels[(i + dir + channels.count) % channels.count])
    }

    // MARK: - loading

    private func loadChannels() async {
        guard let m = media else { return }
        if !spec.channels { channels = []; return }
        // Zapping within the same list keeps it; a channel from elsewhere fetches its own list.
        if !channels.contains(where: { $0.key == m.key }) { channels = (try? await api.channels(m.plugin, m.id)) ?? [] }
    }

    private func loadEpg() async {
        guard let m = media, spec.guide else { return }
        var ids = [m.id]
        for c in channels where c.plugin == m.plugin && !ids.contains(c.id) { ids.append(c.id) }
        while !Task.isCancelled {
            if let e = try? await api.epg(m.plugin, ids) { epg = e }
            try? await Task.sleep(nanoseconds: 180_000_000_000)
        }
    }

    private func loadQueue() async {
        queue = nil
        guard let m = media, spec.queue else { queueOpen = false; return }
        queue = try? await api.queue(m.plugin, m.id)
        if queue?.items.isEmpty ?? true { queueOpen = false }
    }

    // MARK: - the plugin's choices

    /// The plugin's own choices (type "choice") go with the stream address: ?opt.<id>=<value>.
    private func optValue(_ m: Media, _ s: SpecSection) -> String? {
        if let v = Prefs.shared.pluginOpt(m.plugin, s.id), s.options.contains(where: { $0.id == v }) { return v }
        return s.defaultValue
    }

    private func urlFor(_ m: Media) -> String {
        let choices = m.player?.settings.filter { $0.type == "choice" } ?? []
        if choices.isEmpty { return m.url }
        return m.url + (m.url.contains("?") ? "&" : "?") + choices.map { "opt.\($0.id)=" + enc(optValue(m, $0) ?? "") }.joined(separator: "&")
    }

    private func settingsSections() -> [(String, [TrackOption])] {
        _ = optVersion
        _ = controller.tracksVersion
        let m = media
        var out = [(String, [TrackOption])]()
        for s in spec.settings {
            switch s.type {
            case "chat":
                if m?.chat == true {
                    out.append((s.title ?? tr("Chat"), [
                        TrackOption(label: tr("Show the chat"), selected: showChat) { if !showChat { toggleChat() } },
                        TrackOption(label: tr("Hide the chat"), selected: !showChat) { if showChat { toggleChat() } },
                    ]))
                }
            case "audio":
                let tracks = controller.audioTracks
                if tracks.count > 1 {
                    out.append((s.title ?? tr("Audio"), tracks.map { t in TrackOption(label: t.name, selected: t.id == controller.currentAudio) { controller.setAudio(t) } }))
                }
            case "subtitles":
                let tracks = controller.subtitleTracks
                if !tracks.isEmpty {
                    var opts = [TrackOption(label: tr("Off"), selected: controller.currentSubtitle < 0) { controller.setSubtitle(nil) }]
                    opts += tracks.map { t in TrackOption(label: t.name, selected: t.id == controller.currentSubtitle) { controller.setSubtitle(t) } }
                    out.append((s.title ?? tr("Subtitles"), opts))
                }
            case "choice":
                if let m {
                    out.append((s.title ?? s.id, s.options.map { o in
                        TrackOption(label: o.label, selected: optValue(m, s) == o.id) {
                            Prefs.shared.setPluginOpt(m.plugin, s.id, o.id)
                            optVersion += 1
                        }
                    }))
                }
            case "actions":
                out.append((s.title ?? tr("Actions"), s.options.map { o in
                    TrackOption(label: o.label, selected: false, action: true) { sync.playerAction(o.id); settingsPanel = false }
                }))
            default:
                break // "quality" – VLC picks the stream's quality itself
            }
        }
        return out
    }

    // MARK: - overlays

    @ViewBuilder
    private func overlay(_ st: RoomState, _ m: Media) -> some View {
        let hints = keyHints(spec, m, chatOn: chatVisible, hasChannels: !channels.isEmpty, hasQueue: !(queue?.items.isEmpty ?? true))
        let top = AnyView(TopStrip(st: st, members: sync.members, connected: sync.connected))
        if let ov = spec.overlay {
            // The plugin's own overlay, bound to {{media}} and {{player}}.
            let position = pendingSeek ?? controller.positionSec
            let duration = controller.durationSec
            let player: JSON = [
                "position": position, "duration": duration, "positionText": formatTime(position),
                "remainingText": duration > 0 ? "-" + formatTime(duration - position) : "",
                "progress": duration > 0 ? position / duration : 0.0,
                "paused": st.paused && !st.waiting, "waiting": st.waiting, "seeking": pendingSeek != nil,
                "status": controller.status, "hints": hints,
            ]
            PluginOverlay(sync: sync, api: api, plugin: m.plugin, node: ov, media: m.toJSON(), player: player, topbar: top)
        } else if m.live && spec.guide {
            LiveOverlay(st: st, media: m, epg: epg[m.id], channel: channels.first { $0.key == m.key }, top: top, status: controller.status, api: api, hints: hints)
        } else if m.live {
            StreamOverlay(media: m, top: top, status: controller.status, api: api, hints: hints)
        } else {
            VodOverlay(st: st, media: m, top: top, status: controller.status, position: pendingSeek ?? controller.positionSec,
                       duration: controller.durationSec, seeking: pendingSeek != nil, hints: hints)
        }
    }
}

/// When the plugin sent nothing: OK pause, ◀▶ seek (not live), ▼ settings, ▲ info.
private func defaultSpec(_ media: Media?) -> PlayerSpec {
    let live = media?.live == true
    var settings = [SpecSection]()
    if media?.chat == true { settings.append(SpecSection(id: "chat", type: "chat", title: nil)) }
    settings += [SpecSection(id: "audio", type: "audio", title: nil), SpecSection(id: "subtitles", type: "subtitles", title: nil)]
    return PlayerSpec(
        keys: ["ok": "pause", "up": "info", "down": "settings",
               "left": live ? (media?.chat == true ? "chat" : "none") : "seek_back", "right": live ? "settings" : "seek_forward"],
        settings: settings, channels: false, guide: false
    )
}

/// The help line at the bottom, built from what the plugin's keys do.
@MainActor
private func keyHints(_ spec: PlayerSpec, _ media: Media, chatOn: Bool, hasChannels: Bool, hasQueue: Bool) -> String {
    let glyphs = [("ok", "OK"), ("up", "▲"), ("down", "▼"), ("left", "◀"), ("right", "▶")]
    var order = [String]()
    var merged = [String: [String]]()
    for (k, glyph) in glyphs {
        let label: String?
        switch spec.keys[k] {
        case "pause": label = tr("play or pause")
        case "settings": label = tr("settings")
        case "chat": label = media.chat ? (chatOn ? tr("hide chat") : tr("show chat")) : nil
        case "channels": label = hasChannels ? tr("channel list") : nil
        case "channel_up", "channel_down": label = hasChannels ? tr("change channel") : nil
        case "seek_back", "seek_forward": label = media.live ? nil : tr("skip 10 s")
        case "queue": label = hasQueue ? tr("up next") : nil
        default: label = nil
        }
        guard let label else { continue }
        if merged[label] == nil { order.append(label) }
        merged[label, default: []].append(glyph)
    }
    return (order.map { "\(merged[$0]!.joined())  \($0)" } + [tr("Menu") + "  " + tr("back")]).joined(separator: "   ·   ")
}
