import SwiftUI

// MARK: - search

/// Searches every plugin at once. Results appear while you type.
struct SearchView: View {
    @ObservedObject var sync: SyncClient
    let api: Api
    @State var query = ""
    @State var result: [PluginResult]?
    @State var loading = false
    @State var error: String?
    @State var opened: Item?

    var body: some View {
        if let o = opened {
            ViewHost(sync: sync, api: api, root: ViewRef.forItem(o), onExit: { opened = nil }).id(o.key)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14.dp) {
                    PathIcon(path: AppIcon.search, size: 26).foregroundStyle(Palette.dim)
                    TextField(tr("Search everything…"), text: $query)
                        .font(.s(22))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .frame(maxWidth: 1100.dp, alignment: .leading)
                let sections = (result ?? []).flatMap { p in p.sections.filter { !$0.items.isEmpty }.map { (p, $0) } }
                Text(statusText(sections.isEmpty))
                    .font(.s(14)).foregroundStyle(error != nil ? Palette.error : Palette.faint)
                    .padding(.leading, 28.dp).padding(.top, 4.dp).padding(.bottom, 8.dp)
                if !sections.isEmpty {
                    let several = (result ?? []).count > 1
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22.dp) {
                            ForEach(Array(sections.enumerated()), id: \.offset) { _, pair in
                                let (p, s) = pair
                                // With several plugins the plugin's name goes in front, e.g. "IPTV · Movies".
                                let title = s.title.map { several ? "\(p.name) · \($0)" : $0 } ?? p.name
                                CardRow(title: title, row: s, api: api, sync: sync, opener: open)
                            }
                        }
                        .padding(.bottom, 24.dp)
                    }
                    .scrollClipDisabled()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16.dp)
            .task(id: query) { await search() }
        }
    }

    private func statusText(_ empty: Bool) -> String {
        if let error { return tr("Error: {message}", ["message": error]) }
        if loading { return tr("Searching…") }
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.count < 2 { return tr("Type at least two characters, or use the microphone on the remote.") }
        if result != nil && empty { return tr("No results for \"{query}\"", ["query": q]) }
        return tr("Hold OK to add to favorites")
    }

    private func open(_ item: Item) {
        if item.opens { opened = item } else { sync.load(item) }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.count < 2 { result = nil; error = nil; return }
        try? await Task.sleep(nanoseconds: 350_000_000)
        if Task.isCancelled { return }
        loading = true
        do {
            result = try await api.search(q)
            error = nil
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
        loading = false
    }
}

// MARK: - history

/// The room's shared history – what you watched, who started it and where you stopped.
struct HistoryView: View {
    @ObservedObject var sync: SyncClient
    let api: Api
    @State var entries: [HistoryEntry]?
    @State var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(tr("History")).font(.s(24, .bold))
                Text("   " + tr("What you have watched together")).font(.s(16)).foregroundStyle(Palette.faint)
                Spacer()
                if !(entries ?? []).isEmpty {
                    Pill(text: tr("Clear history")) { sync.historyClear(); entries = [] }
                }
            }
            .padding(.leading, 12.dp).padding(.bottom, 14.dp)
            if let list = entries {
                if list.isEmpty {
                    Text(tr("Nothing here yet. Everything you start is saved here, and movies and episodes can be resumed where you left off."))
                        .font(.s(16)).foregroundStyle(Palette.dim).padding(12.dp)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2.dp) {
                            ForEach(list) { e in
                                HistoryRow(e: e, playingNow: sync.state?.media?.key == e.key, iconUrl: api.abs(e.image),
                                           onPlay: { play(e) }, onRestart: { play(e, fromStart: true) },
                                           onRemove: { sync.historyRemove(e.key); entries = entries?.filter { $0.key != e.key } })
                            }
                        }
                        .padding(8.dp)
                    }
                    .background(RoundedRectangle(cornerRadius: 12.dp).fill(Palette.panel))
                }
            } else if let error {
                Message(text: tr("Error: {message}", ["message": error]), error: true)
            } else {
                Message(text: tr("Loading…"))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16.dp)
        .task(id: sync.historyVersion) {
            while !Task.isCancelled {
                do { entries = try await api.history(); error = nil } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private func play(_ e: HistoryEntry, fromStart: Bool = false) {
        sync.load(e.toItem(), position: !fromStart && e.resumable ? e.position : 0)
    }
}

private struct HistoryRow: View {
    let e: HistoryEntry
    let playingNow: Bool
    let iconUrl: String?
    let onPlay: () -> Void
    let onRestart: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8.dp) {
            FocusRow(selected: playingNow, height: 92, action: onPlay) {
                Group {
                    if e.live {
                        Thumb(url: iconUrl, fallback: e.title).frame(width: 110.dp, height: 62.dp)
                    } else {
                        Thumb(url: iconUrl, fallback: e.title, fit: false).frame(width: 52.dp, height: 78.dp).frame(width: 110.dp)
                    }
                }
                Spacer().frame(width: 18.dp)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10.dp) {
                        Text(e.title).font(.s(18, .semibold)).lineLimit(1)
                        if e.live { LiveBadge() }
                        if playingNow { Text(tr("▶ Playing now")).font(.s(13)) }
                    }
                    if let s = e.subtitle { Text(s).font(.s(14)).opacity(0.7).lineLimit(1) }
                    HStack(spacing: 14.dp) {
                        Text([e.startedBy.map { tr("{name} started it", ["name": $0]) }, whenText(e.lastAt)].compactMap { $0 }.joined(separator: "  ·  "))
                            .font(.s(13)).opacity(0.6)
                        if let r = remaining(e) { Text(r).font(.s(13)).foregroundStyle(e.finished ? Palette.green : Color(hex: 0x99FFFFFF)) }
                    }
                    .padding(.top, 4.dp)
                    if !e.live && e.duration != nil {
                        ProgressLine(fraction: e.fraction, color: e.finished ? Palette.green : Color(hex: 0xE6FFFFFF)).frame(maxWidth: 500.dp).padding(.top, 6.dp)
                    }
                }
                Spacer(minLength: 0)
                if !e.live { Text(e.resumable ? tr("Resume") : tr("Play")).font(.s(14)).opacity(0.8) }
            }
            if e.resumable { Pill(text: tr("Start over"), action: onRestart) }
            Pill(text: tr("Remove"), action: onRemove)
        }
    }

    private func whenText(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let time = hhmm(ms / 1000)
        if Calendar.current.isDateInToday(d) { return tr("today {time}", ["time": time]) }
        if Calendar.current.isDateInYesterday(d) { return tr("yesterday {time}", ["time": time]) }
        let f = DateFormatter()
        f.locale = I18n.shared.locale
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return "\(f.string(from: d)) \(time)"
    }

    private func remaining(_ e: HistoryEntry) -> String? {
        guard let d = e.duration else { return nil }
        if e.finished { return tr("Watched") }
        let min = max(1, Int((d - e.position) / 60))
        return min >= 60 ? tr("{h} h {m} min remaining", ["h": min / 60, "m": min % 60]) : tr("{m} min remaining", ["m": min])
    }
}

// MARK: - favourites

/// The room's shared favourites, from every plugin, in the groups the plugins name.
struct FavoritesView: View {
    @ObservedObject var sync: SyncClient
    let api: Api
    @State var opened: Favorite?
    @State var guideFor: Favorite?
    @State var epg: [String: [Program]] = [:]

    var body: some View {
        if let o = opened {
            ViewHost(sync: sync, api: api, root: ViewRef.forItem(o.toItem()), onExit: { opened = nil }).id(o.key)
        } else if let g = guideFor {
            VStack(alignment: .leading, spacing: 12.dp) {
                HStack(spacing: 8.dp) {
                    Pill(text: tr("‹  Back")) { guideFor = nil }
                    Pill(text: tr("Watch now"), selected: true) { sync.load(g.toItem()) }
                    Pill(text: tr("Remove from favorites")) { sync.favRemove(g.key); guideFor = nil }
                }
                .padding(.leading, 12.dp)
                ChannelGuide(item: g.toItem(), shortEpg: epg[g.key], api: api, sync: sync)
            }
            .onExitCommand { guideFor = nil }
        } else {
            list
        }
    }

    private var list: some View {
        let favorites = sync.favorites
        let reminders = sync.reminders
        let sorted = favorites.sorted { a, b in a.newCount != b.newCount ? a.newCount > b.newCount : (a.live && !b.live) }
        var groups = [FavGroup]()
        for f in sorted where !groups.contains(where: { $0.id == f.group.id }) { groups.append(f.group) }
        groups.sort { $0.order != $1.order ? $0.order < $1.order : $0.title < $1.title }
        let channels = favorites.filter { $0.group.style == "guide" }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(tr("Favorites")).font(.s(24, .bold))
                Text("   " + tr("Shared with everyone in the room  ·  Hold OK: remove (channels: guide)")).font(.s(15)).foregroundStyle(Palette.faint)
            }
            .padding(.leading, 12.dp).padding(.bottom, 14.dp)
            if favorites.isEmpty && reminders.isEmpty {
                Text(tr("No favorites yet. Hold OK on anything to add it. New episodes of favorite series are marked here."))
                    .font(.s(16)).foregroundStyle(Palette.dim).padding(12.dp)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22.dp) {
                        if !reminders.isEmpty {
                            section(tr("Reminders"), reminders.count) {
                                ForEach(reminders) { r in
                                    FocusRow(height: 84, onLongPress: { sync.reminderRemove(r.key) }, action: { sync.load(r.channel) }) {
                                        PathIcon(path: AppIcon.bell, size: 22).foregroundStyle(Palette.gold)
                                        Spacer().frame(width: 14.dp)
                                        VStack(alignment: .leading) {
                                            Text("\(dayLabel(r.start)) \(hhmm(r.start))").font(.s(14, .bold)).foregroundStyle(Palette.gold)
                                            Text(r.title).font(.s(16, .medium)).lineLimit(1)
                                            Text(r.channel.title + (r.addedBy.map { " · " + tr("by {name}", ["name": $0]) } ?? "")).font(.s(13)).foregroundStyle(Palette.dim).lineLimit(1)
                                        }
                                    }
                                    .frame(width: 380.dp)
                                    .background(RoundedRectangle(cornerRadius: 8.dp).fill(Palette.panel))
                                }
                            }
                        }
                        ForEach(groups, id: \.id) { g in
                            let items = sorted.filter { $0.group.id == g.id }
                            section(g.title, items.count) {
                                ForEach(items) { f in card(f, style: g.style) }
                            }
                        }
                    }
                    .padding(.bottom, 24.dp)
                }
                .scrollClipDisabled()
            }
        }
        .padding(.horizontal, 16.dp)
        .task(id: channels.map(\.key).joined(separator: ",")) {
            // Now/next for the favourite channels, per plugin.
            if channels.isEmpty { return }
            while !Task.isCancelled {
                var out = [String: [Program]]()
                for (plugin, list) in Dictionary(grouping: channels, by: \.plugin) {
                    if let m = try? await api.epg(plugin, list.map(\.id)) { for (id, p) in m { out["\(plugin):\(id)"] = p } }
                }
                epg = out
                try? await Task.sleep(nanoseconds: 180_000_000_000)
            }
        }
    }

    @ViewBuilder
    private func card(_ f: Favorite, style: String) -> some View {
        switch style {
        case "guide":
            ChannelRow(item: f.toItem(), epg: epg[f.key], now: nowSec(), playing: false, iconUrl: api.abs(f.image), favorite: true,
                       onLongPress: { guideFor = f }, onClick: { sync.load(f.toItem()) })
                .frame(width: 380.dp)
                .background(RoundedRectangle(cornerRadius: 8.dp).fill(Palette.panel))
        case "poster":
            PosterCard(title: cleanTitle(f.title), image: api.abs(f.image), favorite: true, newCount: f.newCount,
                       caption: f.newCount > 0 ? f.newLabel.map { tr("New: {episode}", ["episode": $0]) } : nil,
                       onClick: { if f.action == "open" { opened = f } else { sync.load(f.toItem()) } },
                       onLongPress: { sync.favRemove(f.key) })
        default:
            LandscapeCard(item: f.toItem(), api: api, favorite: true,
                          onClick: { if f.action == "open" { opened = f } else { sync.load(f.toItem()) } },
                          onLongPress: { sync.favRemove(f.key) })
        }
    }

    private func section<C: View>(_ title: String, _ count: Int, @ViewBuilder content: () -> C) -> some View {
        let inner = content()
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(title).font(.s(20, .bold))
                Text("  \(count)").font(.s(20)).foregroundStyle(Palette.faint)
            }
            .padding(.leading, 12.dp).padding(.bottom, 8.dp)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16.dp) { inner }
                    .padding(.horizontal, 12.dp).padding(.vertical, 10.dp)
            }
            .scrollClipDisabled()
        }
    }
}
