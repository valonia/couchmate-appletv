import SwiftUI

/// The search entry's key in the menu (always at the top).
let searchKey = "core/search"

/// The menu on the left and what is chosen in it on the right.
struct BrowseView: View {
    @ObservedObject var sync: SyncClient
    let api: Api
    let onOpenPlayer: () -> Void
    let onReconnect: () -> Void
    @State var menu: [MenuEntry]?
    @State var menuError: String?
    @State var selected: String?
    @State var showMembers = false
    @State var showSettings = false
    @FocusState var navFocus: String?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            HStack(spacing: 0) {
                SideNav(entries: menu ?? [], selected: selected ?? "", sync: sync, focus: $navFocus,
                        onSelect: { selected = $0 }, onOpenPlayer: onOpenPlayer, onSettings: { showSettings = true },
                        onMembers: { showMembers = true })
                content
                    .padding(EdgeInsets(top: 22.dp, leading: 20.dp, bottom: 20.dp, trailing: 24.dp))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .focusSection()
                    // Menu in the content goes back to the menu on the left; in the menu itself it leaves the app.
                    .onExitCommand { navFocus = selected ?? searchKey }
            }
            if showMembers { MembersPanel(members: sync.members, playing: sync.state?.media?.title, onClose: { showMembers = false }) }
            if let r = sync.state?.reminder, !showMembers {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    ReminderCard(reminder: r, secondsLeft: max(0, (r.switchAt - sync.serverNow() + 999) / 1000), interactive: true,
                                 onNow: { sync.reminderNow() }, onCancel: { sync.reminderCancel() })
                }
                .padding(36.dp)
            }
            NoticeToast(sync: sync).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 24.dp).allowsHitTesting(false)
            if showSettings {
                SettingsDialog(onClose: { showSettings = false }, onReconnect: { showSettings = false; onReconnect() },
                               onLanguage: { sync.languageChanged(); sync.menuVersion += 1 })
            }
        }
        .background(Palette.bg.ignoresSafeArea())
        // The menu comes from the server: fetched again when a plugin or the order changes, otherwise every minute.
        .task(id: "\(sync.menuVersion)|\(sync.connected)") {
            while !Task.isCancelled {
                do { menu = try await api.menu(); menuError = nil } catch { if menu == nil { menuError = error.localizedDescription } }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        // Start on the first entry; if the chosen one disappears (plugin switched off), go to the first.
        .onChange(of: menu?.map(\.key)) { _, keys in
            guard let keys else { return }
            if selected == nil || (selected != searchKey && !keys.contains(selected!)) { selected = keys.first ?? searchKey }
        }
    }

    @ViewBuilder
    private var content: some View {
        let entry = menu?.first { $0.key == selected }
        if selected == searchKey {
            SearchView(sync: sync, api: api)
        } else if entry?.core == "favorites" {
            FavoritesView(sync: sync, api: api)
        } else if entry?.core == "history" {
            HistoryView(sync: sync, api: api)
        } else if let entry, let plugin = entry.plugin {
            // A plugin's menu entry: its own view, built by the plugin (open → more views, Menu → back).
            ViewHost(sync: sync, api: api, root: ViewRef(plugin: plugin, id: entry.id)).id(entry.key)
        } else if menu == nil, let menuError {
            Message(text: tr("Error: {message}", ["message": menuError]), error: true)
        } else if menu == nil {
            Message(text: tr("Loading…"))
        } else if !(menu ?? []).contains(where: { $0.plugin != nil }) {
            Message(text: tr("Nothing to watch yet. Switch on a plugin in the admin panel on the server."))
        }
    }
}

/// The menu on the left: Search, the server's entries (in the order chosen in the admin panel), Settings,
/// what plays, who is connected and the clock. It widens to show the names while focus is in it.
struct SideNav: View {
    let entries: [MenuEntry]
    let selected: String
    @ObservedObject var sync: SyncClient
    var focus: FocusState<String?>.Binding
    let onSelect: (String) -> Void
    let onOpenPlayer: () -> Void
    let onSettings: () -> Void
    let onMembers: () -> Void
    @Environment(\.isFocused) var anyFocused

    var body: some View {
        let expanded = focus.wrappedValue != nil
        let newEpisodes = sync.favorites.reduce(0) { $0 + $1.newCount }
        VStack(alignment: .leading, spacing: 4.dp) {
            HStack(spacing: 12.dp) {
                Image(systemName: "sofa.fill").font(.system(size: 30.dp)).foregroundStyle(Palette.accent).frame(width: 36.dp)
                if expanded {
                    (Text("Couch").foregroundStyle(Palette.text) + Text("mate").foregroundStyle(Palette.accent)).font(font(22, .bold))
                }
            }
            .frame(height: 48.dp).padding(.leading, 10.dp).padding(.bottom, 14.dp)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4.dp) {
                    navItem(key: searchKey, icon: AppIcon.search, label: tr("Search"), expanded: expanded) { onSelect(searchKey) }
                    ForEach(entries) { e in
                        navItem(key: e.key, icon: e.core != nil ? AppIcon.forCore(e.core) : (e.icon ?? AppIcon.liveTv), label: e.title, expanded: expanded,
                                badge: e.core == "favorites" && newEpisodes > 0 ? "\(newEpisodes)" : nil) { onSelect(e.key) }
                    }
                    navItem(key: "core/settings", icon: AppIcon.settings, label: tr("Settings"), expanded: expanded, selectable: false, action: onSettings)
                }
            }
            .scrollClipDisabled()

            if let m = sync.state?.media {
                navItem(key: "core/playing", icon: AppIcon.play, label: m.title, expanded: expanded, sublabel: tr("Now playing"), accent: true, selectable: false, action: onOpenPlayer)
                navItem(key: "core/stop", icon: AppIcon.stop, label: tr("Stop for everyone"), expanded: expanded, selectable: false) { sync.stopPlayback() }
                Spacer().frame(height: 6.dp)
            }
            Button(action: onMembers) {
                HStack(spacing: 14.dp) {
                    Group {
                        if !sync.connected || sync.members.isEmpty {
                            Circle().fill(sync.connected ? Palette.green : Palette.live).frame(width: 10.dp, height: 10.dp).padding(.leading, 10.dp)
                        } else {
                            ZStack(alignment: .bottomTrailing) {
                                Avatar(name: sync.members[0].name, size: 30)
                                if sync.members.count > 1 {
                                    Text("\(sync.members.count)").font(font(10, .bold)).foregroundStyle(.white)
                                        .padding(.horizontal, 5.dp).background(Capsule().fill(Palette.accent)).offset(x: 6.dp, y: 4.dp)
                                }
                            }
                        }
                    }
                    .frame(width: 32.dp, alignment: .leading)
                    if expanded {
                        Text(!sync.connected ? (sync.error ?? tr("Connecting…")) : sync.members.isEmpty ? tr("Connected") : viewersText(sync.members))
                            .font(font(14)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 12.dp).frame(height: 52.dp)
            }
            .buttonStyle(FocusStyle(look: .nav))
            .focused(focus, equals: "core/members")
            ClockView(size: expanded ? 22 : 16).padding(.leading, 10.dp).padding(.top, 8.dp)
        }
        .padding(.horizontal, 12.dp).padding(.vertical, 18.dp)
        .frame(width: expanded ? 250.dp : 80.dp, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.panel.ignoresSafeArea())
        .animation(.easeOut(duration: 0.22), value: expanded)
        .focusSection()
        // Coming back to the menu puts focus on the chosen entry.
        .defaultFocus(focus, selected.isEmpty ? searchKey : selected)
    }

    private func navItem(key: String, icon: String, label: String, expanded: Bool, badge: String? = nil, sublabel: String? = nil,
                         accent: Bool = false, selectable: Bool = true, action: @escaping () -> Void) -> some View {
        let isSelected = selectable && key == selected
        return Button(action: action) {
            HStack(spacing: 16.dp) {
                ZStack(alignment: .topTrailing) {
                    PathIcon(path: icon, size: 24)
                    if badge != nil && !expanded { Circle().fill(Palette.live).frame(width: 10.dp, height: 10.dp).offset(x: 5.dp, y: -4.dp) }
                }
                if expanded {
                    VStack(alignment: .leading, spacing: 0) {
                        if let sublabel { Text(sublabel.uppercased()).font(font(10, .bold)).tracking(1.dp).foregroundStyle(Palette.accent) }
                        Text(label).font(font(17, isSelected ? .semibold : .medium)).lineLimit(1)
                    }
                    if let badge {
                        Text(badge).font(font(11, .bold)).foregroundStyle(.white).padding(.horizontal, 7.dp).padding(.vertical, 1.dp).background(Capsule().fill(Palette.live))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 16.dp).padding(.trailing, 10.dp)
            .frame(height: (sublabel != nil && expanded ? 60 : 52).dp)
        }
        .buttonStyle(FocusStyle(look: .nav, selected: isSelected, accent: accent))
        .focused(focus, equals: key)
        // Moving through the menu shows the entry straight away (like the Android app).
        .onChange(of: focus.wrappedValue) { _, f in if f == key && selectable { onSelect(key) } }
    }
}

/// Everyone who is connected – opened from the chip at the bottom of the menu.
struct MembersPanel: View {
    let members: [Member]
    let playing: String?
    let onClose: () -> Void
    var body: some View {
        let sorted = members.sorted { a, b in a.watching != b.watching ? a.watching : a.name.lowercased() < b.name.lowercased() }
        HStack(spacing: 0) {
            Color(hex: 0x99000000)
            VStack(alignment: .leading, spacing: 0) {
                Text(tr("{n} connected", ["n": members.count])).font(font(22, .bold))
                Text(playing.map { tr("Watching {title}", ["title": $0]) } ?? tr("Nothing is playing right now"))
                    .font(font(14)).foregroundStyle(Palette.faint).lineLimit(1).padding(.top, 2.dp).padding(.bottom, 16.dp)
                ScrollView {
                    VStack(spacing: 2.dp) {
                        ForEach(sorted) { m in
                            FocusRow(height: 60, action: {}) {
                                Avatar(name: m.name, size: 34)
                                Spacer().frame(width: 14.dp)
                                VStack(alignment: .leading) {
                                    Text(m.name).font(font(17, .medium)).lineLimit(1)
                                    if !m.device.isEmpty { Text(m.device).font(font(13)).opacity(0.6).lineLimit(1) }
                                }
                                Spacer(minLength: 0)
                                Text(m.watching ? tr("Watching") : tr("In the menu")).font(font(13)).foregroundStyle(m.watching ? Palette.green : Color(hex: 0x99FFFFFF))
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                Text(tr("Menu  –  close")).font(font(13)).foregroundStyle(Palette.faint)
            }
            .padding(EdgeInsets(top: 32.dp, leading: 24.dp, bottom: 24.dp, trailing: 24.dp))
            .frame(width: 460.dp)
            .frame(maxHeight: .infinity)
            .background(Palette.panel)
        }
        .ignoresSafeArea()
        .focusSection()
        .onExitCommand(perform: onClose)
    }
}
