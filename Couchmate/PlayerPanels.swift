import SwiftUI

/// A choice in the settings panel (a subtitle, an audio track, a plugin's option …).
struct TrackOption {
    let label: String
    let selected: Bool
    var action = false
    let apply: () -> Void
    init(label: String, selected: Bool, action: Bool = false, apply: @escaping () -> Void) {
        self.label = label
        self.selected = selected
        self.action = action
        self.apply = apply
    }
}

struct StatusChip: View {
    let text: String
    var body: some View {
        Text(text).font(.s(15)).foregroundStyle(Palette.text)
            .padding(.horizontal, 16.dp).padding(.vertical, 8.dp)
            .background(Capsule().fill(Color(hex: 0xCC0A0C10)))
    }
}

/// "Bob paused" – who did what, for the top strip.
@MainActor
private func actionText(_ who: String, _ a: String?) -> String? {
    switch a {
    case "load": return tr("{name} started the video", ["name": who])
    case "play", "start": return tr("{name} pressed play", ["name": who])
    case "pause": return tr("{name} paused the video", ["name": who])
    case "seek": return tr("{name} skipped forward in the video", ["name": who])
    default: return nil
    }
}

/// The top strip: who did what + who is watching + the clock.
struct TopStrip: View {
    let st: RoomState
    let members: [Member]
    let connected: Bool
    var body: some View {
        HStack(spacing: 20.dp) {
            if let who = st.changedBy, let t = actionText(who, st.action) { Text(t).font(.s(17)).foregroundStyle(Palette.dim) }
            Spacer()
            ViewersChip(connected: connected, members: members.filter(\.watching))
            ClockView(size: 26)
        }
        .padding(EdgeInsets(top: 32.dp, leading: 56.dp, bottom: 60.dp, trailing: 56.dp))
        .background(LinearGradient(colors: [Color(hex: 0xD9000000), .clear], startPoint: .top, endPoint: .bottom))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The bottom part of the overlays: gradient, content, then status + key hints.
private struct BottomPanel<Content: View>: View {
    let status: String
    let hints: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16.dp) {
            content()
            HStack {
                if !status.isEmpty { Text(status).font(.s(14)).foregroundStyle(Palette.status) }
                Spacer()
                Text(hints).font(.s(13)).foregroundStyle(Palette.faint)
            }
        }
        .padding(EdgeInsets(top: 80.dp, leading: 56.dp, bottom: 40.dp, trailing: 56.dp))
        .background(LinearGradient(colors: [.clear, Color(hex: 0xF00A0C10)], startPoint: .top, endPoint: .bottom))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

/// The overlay for live streams without a guide: picture, title, channel and LIVE.
struct StreamOverlay: View {
    let media: Media
    let top: AnyView
    let status: String
    let api: Api
    let hints: String
    var body: some View {
        ZStack {
            top
            BottomPanel(status: status, hints: hints) {
                HStack(spacing: 24.dp) {
                    Thumb(url: api.abs(media.image), fallback: media.subtitle ?? media.title, corner: 10).frame(width: 150.dp, height: 84.dp)
                    VStack(alignment: .leading, spacing: 6.dp) {
                        HStack(spacing: 12.dp) {
                            Text(media.subtitle ?? media.title).font(.s(22, .bold)).lineLimit(1)
                            LiveBadge()
                        }
                        if media.subtitle != nil { Text(media.title).font(.s(18)).foregroundStyle(Palette.dim).lineLimit(2) }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// The overlay for channels with a programme guide: number, name, what is on now and next.
struct LiveOverlay: View {
    let st: RoomState
    let media: Media
    let epg: [Program]?
    let channel: Item?
    let top: AnyView
    let status: String
    let api: Api
    let hints: String
    var body: some View {
        let t = nowSec()
        let cur = epg?.now(t)
        let nxt = epg?.next(t)
        ZStack {
            top
            BottomPanel(status: status, hints: hints) {
                HStack(spacing: 24.dp) {
                    Thumb(url: api.abs(media.image), fallback: media.title, corner: 10).frame(width: 150.dp, height: 84.dp)
                    VStack(alignment: .leading, spacing: 6.dp) {
                        HStack(spacing: 12.dp) {
                            if let n = channel?.number { Text("\(n)").font(.s(20)).foregroundStyle(Palette.dim) }
                            Text(media.title).font(.s(26, .bold)).lineLimit(1)
                            LiveBadge()
                        }
                        Text(cur?.title ?? tr("No programme information")).font(.s(19)).foregroundStyle(cur != nil ? Palette.text : Palette.faint).lineLimit(1)
                        if let cur {
                            HStack(spacing: 12.dp) {
                                Text(hhmm(cur.start)).font(.s(14)).foregroundStyle(Palette.dim)
                                ProgressLine(fraction: cur.progress(t))
                                Text(hhmm(cur.end)).font(.s(14)).foregroundStyle(Palette.dim)
                            }
                            .padding(.top, 4.dp)
                        }
                        if let nxt {
                            Text(tr("Up next") + "  \(hhmm(nxt.start))  \(nxt.title)").font(.s(15)).foregroundStyle(Palette.dim).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// The overlay for movies and episodes: title, progress, time left.
struct VodOverlay: View {
    let st: RoomState
    let media: Media
    let top: AnyView
    let status: String
    let position: Double
    let duration: Double
    let seeking: Bool
    let hints: String
    var body: some View {
        ZStack {
            top
            if st.paused && !st.waiting {
                Text("❚❚").font(.s(64)).foregroundStyle(Color(hex: 0xE6FFFFFF))
                    .padding(.horizontal, 34.dp).padding(.vertical, 18.dp)
                    .background(Capsule().fill(Color(hex: 0x66000000)))
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(media.title).font(.s(30, .bold)).lineLimit(1)
                if let s = media.subtitle { Text(s).font(.s(18)).foregroundStyle(Palette.dim).lineLimit(1) }
                ProgressLine(fraction: duration > 0 ? position / duration : 0, color: seeking ? Palette.gold : Palette.accent, height: 6).padding(.top, 18.dp)
                HStack(spacing: 20.dp) {
                    Text(formatTime(position)).font(.s(16)).foregroundStyle(seeking ? Palette.gold : Palette.text)
                    if !status.isEmpty { Text(status).font(.s(14)).foregroundStyle(Palette.status) }
                    Spacer()
                    Text(hints).font(.s(13)).foregroundStyle(Palette.faint)
                    Text(duration > 0 ? "-" + formatTime(duration - position) : "").font(.s(16)).foregroundStyle(Palette.dim)
                }
                .padding(.top, 10.dp)
            }
            .padding(EdgeInsets(top: 80.dp, leading: 56.dp, bottom: 40.dp, trailing: 56.dp))
            .background(LinearGradient(colors: [.clear, Color(hex: 0xF00A0C10)], startPoint: .top, endPoint: .bottom))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }
}

/// "Next": starts by itself; OK plays it now, Menu cancels.
struct UpNextCard: View {
    let upNext: UpNext
    let secondsLeft: Double
    let api: Api
    var body: some View {
        HStack(spacing: 18.dp) {
            Thumb(url: api.abs(upNext.item.image), fallback: upNext.item.title, fit: false, corner: 8).frame(width: 150.dp, height: 84.dp)
            VStack(alignment: .leading, spacing: 0) {
                Text(tr("UP NEXT")).font(.s(12, .bold)).tracking(1.5.dp).foregroundStyle(Palette.accent)
                Text(upNext.item.title).font(.s(18, .semibold)).lineLimit(1)
                if let s = upNext.item.subtitle { Text(s).font(.s(15)).foregroundStyle(Palette.dim).lineLimit(1) }
                Text(tr("Starts in {n} s   ·   OK play now   ·   Menu cancel", ["n": Int(secondsLeft) + 1])).font(.s(13)).foregroundStyle(Palette.faint).padding(.top, 8.dp)
            }
            Spacer(minLength: 0)
        }
        .padding(18.dp)
        .frame(width: 560.dp)
        .background(RoundedRectangle(cornerRadius: 14.dp).fill(Color(hex: 0xF00A0C10)))
    }
}

/// What plays next, to the right of the video. The one playing now is marked; OK plays the chosen one for everyone.
/// Greyed-out ones (e.g. a song not found on YouTube) show but are never played.
struct QueuePanel: View {
    let queue: Queue
    let api: Api
    let onPick: (Item) -> Void
    @State var focusedItem: Item?

    var body: some View {
        let currentIdx = queue.items.firstIndex { $0.id == queue.current } ?? -1
        let startIdx = currentIdx + 1 < queue.items.count ? currentIdx + 1 : max(0, currentIdx)
        let keys = uniqueKeys(queue.items)
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("Up next")).font(.s(16, .bold)).foregroundStyle(Palette.dim).padding(.leading, 8.dp)
            if let t = queue.title { Text(t).font(.s(13)).foregroundStyle(Palette.faint).lineLimit(1).padding(.leading, 8.dp).padding(.top, 2.dp) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4.dp) {
                        ForEach(Array(queue.items.enumerated()), id: \.offset) { idx, item in
                            let playing = idx == currentIdx
                            FocusRow(selected: playing, height: 76,
                                     onFocus: { if !playing && !item.unavailable { focusedItem = item } },
                                     action: { if !item.unavailable { onPick(item) } }) {
                                Text("\(idx + 1)").font(.s(13)).foregroundStyle(Palette.faint).frame(width: 30.dp, alignment: .leading)
                                Thumb(url: api.abs(item.image), fallback: item.title, fit: false, corner: 6).frame(width: 96.dp, height: 54.dp)
                                Spacer().frame(width: 12.dp)
                                VStack(alignment: .leading, spacing: 0) {
                                    if playing { Text(tr("Now playing").uppercased()).font(.s(10, .bold)).tracking(1.dp).foregroundStyle(Palette.accent) }
                                    Text(item.title).font(.s(14, .medium)).lineLimit(playing ? 1 : 2)
                                    let sub = [item.subtitle, item.duration.flatMap { $0 > 0 ? formatTime($0) : nil }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  ")
                                    if !sub.isEmpty { Text(sub).font(.s(12)).opacity(0.7).lineLimit(1) }
                                }
                                Spacer(minLength: 0)
                            }
                            .opacity(item.unavailable ? 0.4 : 1)
                            .id(keys[idx])
                        }
                    }
                }
                .onAppear { if startIdx < keys.count { proxy.scrollTo(keys[max(0, startIdx - 1)], anchor: .top) } }
            }
            .padding(.top, 12.dp)
        }
        .padding(EdgeInsets(top: 22.dp, leading: 14.dp, bottom: 16.dp, trailing: 14.dp))
        .background(Color(hex: 0xFF0E1015))
        .focusSection()
        // The one standing still under the focus for a moment is fetched in advance – it starts quickly if picked.
        .task(id: focusedItem?.key ?? "") {
            guard let it = focusedItem else { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !Task.isCancelled { await api.prepare(it.plugin, it.id) }
        }
    }
}

/// The live chat to the right of the video. Newest at the bottom.
struct ChatPanel: View {
    let messages: [ChatMsg]
    var body: some View {
        VStack(alignment: .leading, spacing: 10.dp) {
            Text(tr("Chat")).font(.s(16, .bold)).foregroundStyle(Palette.dim)
            if messages.isEmpty { Text(tr("Waiting for messages…")).font(.s(14)).foregroundStyle(Palette.faint) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6.dp) {
                        ForEach(messages) { m in
                            (Text(m.user).bold().foregroundColor(m.color.flatMap { Color(css: $0) } ?? Palette.accent) + Text("  " + m.text).foregroundColor(Palette.text))
                                .font(.s(15)).id(m.id)
                        }
                    }
                }
                .onChange(of: messages.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
        .padding(EdgeInsets(top: 22.dp, leading: 18.dp, bottom: 16.dp, trailing: 18.dp))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(hex: 0xFF0E1015))
    }
}

/// A channel list that slides in from the left on top of the video.
struct ChannelPanel: View {
    let title: String
    let channels: [Item]
    let epg: [String: [Program]]
    let currentKey: String?
    let api: Api
    /// The room's favourites (a star on those), and what holding OK on a channel does: add or remove it.
    var favoriteKeys: Set<String> = []
    var onFavorite: ((Item) -> Void)? = nil
    let onPick: (Item) -> Void
    let onClose: () -> Void
    var body: some View {
        let t = nowSec()
        let keys = uniqueKeys(channels)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12.dp) {
                HStack {
                    VStack(alignment: .leading, spacing: 2.dp) {
                        Text(title).font(.s(20, .bold)).lineLimit(1)
                        if onFavorite != nil { Text(tr("Hold OK: favorite")).font(.s(12)).foregroundStyle(Palette.faint) }
                    }
                    Spacer()
                    ClockView(size: 20)
                }
                .padding(.leading, 14.dp)
                if channels.isEmpty {
                    SkeletonRows(count: 9, height: 64)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2.dp) {
                                ForEach(Array(channels.enumerated()), id: \.offset) { idx, item in
                                    ChannelRow(item: item, epg: epg[item.id], now: t, playing: item.key == currentKey, iconUrl: api.abs(item.image),
                                               favorite: favoriteKeys.contains(item.key),
                                               onLongPress: onFavorite.map { f in { f(item) } }) { onPick(item) }
                                        .id(keys[idx])
                                }
                            }
                        }
                        .onAppear {
                            if let i = channels.firstIndex(where: { $0.key == currentKey }) { proxy.scrollTo(keys[max(0, i - 3)], anchor: .top) }
                        }
                    }
                }
            }
            .padding(EdgeInsets(top: 28.dp, leading: 28.dp, bottom: 20.dp, trailing: 20.dp))
            .frame(width: 600.dp)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(LinearGradient(colors: [Color(hex: 0xF50A0C10), Color(hex: 0xE60A0C10)], startPoint: .leading, endPoint: .trailing))
            .focusSection()
            Color(hex: 0x33000000)
        }
        .ignoresSafeArea()
    }
}

/// The player's settings panel from the right: the boxes the plugin chose (this TV only).
struct SettingsPanel: View {
    let sections: [(String, [TrackOption])]
    let onClose: () -> Void
    var body: some View {
        HStack(spacing: 0) {
            Color(hex: 0x33000000)
            VStack(alignment: .leading, spacing: 0) {
                Text(tr("Settings")).font(.s(22, .bold)).padding(.leading, 14.dp)
                Text(tr("Only affects this TV")).font(.s(14)).foregroundStyle(Palette.faint).padding(.leading, 14.dp).padding(.top, 2.dp).padding(.bottom, 14.dp)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2.dp) {
                        ForEach(Array(sections.enumerated()), id: \.offset) { si, section in
                            SectionLabel(text: section.0).padding(.leading, 14.dp).padding(.bottom, 6.dp).padding(.top, si > 0 ? 18.dp : 0)
                            ForEach(Array(section.1.enumerated()), id: \.offset) { _, opt in
                                FocusRow(selected: opt.selected, height: 52, action: opt.apply) {
                                    Text(opt.selected ? "✓" : opt.action ? "›" : "").font(.s(17, .bold)).frame(width: 30.dp, alignment: .leading)
                                    Text(opt.label).font(.s(17)).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        if sections.isEmpty {
                            Text(tr("No settings for this video")).font(.s(14)).foregroundStyle(Palette.faint).padding(.leading, 14.dp)
                        }
                    }
                }
            }
            .padding(EdgeInsets(top: 32.dp, leading: 24.dp, bottom: 24.dp, trailing: 32.dp))
            .frame(width: 460.dp)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(hex: 0xFF0A0C10))
            .focusSection()
        }
        .ignoresSafeArea()
    }
}
