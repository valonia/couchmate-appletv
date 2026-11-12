import SwiftUI

@main
struct CouchmateApp: App {
    init() {
        I18n.shared.configure(Prefs.shared.language)
    }
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}

/// Setup until the server, PIN and name are filled in – then the room. Changing them reconnects.
struct RootView: View {
    @State var configured = Prefs.shared.isConfigured
    @State var connection = 0
    @ObservedObject var i18n = I18n.shared

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()
            if configured {
                RoomView(onReconnect: { connection += 1 }).id(connection)
            } else {
                SetupView(onDone: { configured = true })
            }
        }
    }
}

/// Connected to the room: the menu, or the player when something plays.
struct RoomView: View {
    let onReconnect: () -> Void
    @StateObject var sync: SyncClient
    let api: Api
    @State var inPlayer = false
    @State var seenMedia: String?
    @State var firstVersion: Int?
    @Environment(\.scenePhase) var scenePhase

    init(onReconnect: @escaping () -> Void) {
        self.onReconnect = onReconnect
        let p = Prefs.shared
        let api = Api(base: p.serverUrl, pin: p.pin)
        self.api = api
        let client = SyncClient(api: api, base: p.serverUrl, pin: p.pin, name: p.name)
        client.onRenamed = { Prefs.shared.name = $0 }
        _sync = StateObject(wrappedValue: client)
    }

    var body: some View {
        Group {
            if inPlayer, sync.state?.media != nil {
                PlayerView(sync: sync, api: api, onExit: { inPlayer = false })
            } else {
                BrowseView(sync: sync, api: api, onOpenPlayer: { inPlayer = true }, onReconnect: onReconnect)
            }
        }
        .task { sync.start() }
        .task { await I18n.shared.pump(api) }
        // Connected while the app is in front; the server would otherwise wait for a device nobody watches.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { sync.start() } else if phase == .background { sync.stop() }
        }
        // When someone starts something new, everyone jumps into the player.
        .onChange(of: sync.state?.media?.key) { _, key in
            if key == nil { inPlayer = false } else if key != seenMedia { inPlayer = true }
            seenMedia = key
        }
        // Starting something that already plays (e.g. "Watch now" on the channel that is on) – into the player anyway.
        .onChange(of: sync.state?.version) { _, _ in
            guard let st = sync.state else { return }
            if firstVersion == nil { firstVersion = st.version; return }
            if st.media != nil, st.action == "load", st.changedBy == Prefs.shared.name { inPlayer = true }
        }
    }
}

// MARK: - setup and settings

/// The first start: the logo on the left, the settings form on the right.
struct SetupView: View {
    let onDone: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 48.dp) {
            VStack(alignment: .leading, spacing: 6.dp) {
                (Text("Couch").foregroundStyle(Palette.text) + Text("mate").foregroundStyle(Palette.accent)).font(.s(34, .bold))
                Text(tr("Settings")).font(.s(20)).foregroundStyle(Palette.dim)
                Text(tr("Watch together with your friends, perfectly in sync. Everyone connected to the same server ends up in the same room."))
                    .font(.s(15)).foregroundStyle(Palette.dim).padding(.top, 22.dp)
            }
            .frame(width: 300.dp)
            SettingsForm(onSaved: { _ in onDone() }, onCancel: nil)
                .background(RoundedRectangle(cornerRadius: 16.dp).fill(Palette.panel))
        }
        .padding(.horizontal, 56.dp).padding(.vertical, 44.dp)
    }
}

/// The form: server, PIN, name and language. `onSaved` gets whether the connection changed.
struct SettingsForm: View {
    let onSaved: (Bool) -> Void
    let onCancel: (() -> Void)?
    var onLanguage: () -> Void = {}
    var title: String? = nil
    @State var server = Prefs.shared.serverUrl
    @State var pin = Prefs.shared.pin
    @State var name = Prefs.shared.name
    @State var language = Prefs.shared.language
    @State var status: String?
    @State var testing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28.dp) {
                if let title { Text(title).font(.s(26, .bold)) }
                section(tr("Connection"), tr("The address of your {app} server and the PIN code you were given.", ["app": appName])) {
                    HStack(spacing: 16.dp) {
                        field(tr("Server address"), $server, tr("e.g. 192.168.1.10:8787"), keyboard: .URL)
                        field(tr("PIN code"), $pin, "••••", secure: true).frame(width: 300.dp)
                    }
                }
                section(tr("Profile"), tr("The name the others see when you join.")) {
                    field(tr("Your name"), $name, tr("e.g. Bob")).frame(width: 600.dp)
                }
                section(tr("Language"), tr("Menus and buttons in the TV's language, translated by the server. Applies only on this TV.")) {
                    HStack(spacing: 6.dp) {
                        let system = Locale.current.localizedString(forLanguageCode: Locale.current.language.languageCode?.identifier ?? "en")?.capitalized ?? "English"
                        Pill(text: tr("Same as the TV ({language})", ["language": system]), selected: language == "auto") { setLanguage("auto") }
                        Pill(text: "English", selected: language == "en") { setLanguage("en") }
                    }
                }
                HStack(spacing: 10.dp) {
                    Button(testing ? tr("Connecting…") : Prefs.shared.isConfigured ? tr("Save") : tr("Connect")) { save() }
                        .disabled(testing || server.trimmingCharacters(in: .whitespaces).isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let onCancel { Button(tr("Cancel"), action: onCancel) }
                }
                if let status { Text(status).font(.s(15)).foregroundStyle(Palette.error) }
            }
            .padding(.horizontal, 36.dp).padding(.vertical, 30.dp)
        }
    }

    private func setLanguage(_ code: String) {
        language = code
        Prefs.shared.language = code
        I18n.shared.configure(code)
        onLanguage()
    }

    private func save() {
        let url = normalizeUrl(server)
        let p = Prefs.shared
        let cleanPin = pin.trimmingCharacters(in: .whitespaces)
        let cleanName = name.trimmingCharacters(in: .whitespaces)
        let changed = url != p.serverUrl || cleanPin != p.pin || cleanName != p.name
        if !changed && p.isConfigured { onSaved(false); return }
        testing = true
        status = nil
        Task {
            do {
                let api = Api(base: url, pin: cleanPin)
                let info = try await api.info()
                if !info.ready { throw ApiError(message: tr("The server is not set up yet. Set a PIN code in the admin panel.")) }
                try await api.auth()
                p.serverUrl = url
                p.pin = cleanPin
                p.name = cleanName
                onSaved(true)
            } catch {
                status = tr("Could not connect: {message}", ["message": error.localizedDescription])
            }
            testing = false
        }
    }

    private func section<C: View>(_ title: String, _ description: String, @ViewBuilder content: () -> C) -> some View {
        let inner = content()
        return VStack(alignment: .leading, spacing: 12.dp) {
            VStack(alignment: .leading, spacing: 2.dp) {
                Text(title).font(.s(19, .semibold))
                Text(description).font(.s(14)).foregroundStyle(Palette.faint)
            }
            inner
        }
    }

    private func field(_ label: String, _ value: Binding<String>, _ hint: String, keyboard: UIKeyboardType = .default, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6.dp) {
            Text(label).font(.s(14, .medium)).foregroundStyle(Palette.dim)
            Group {
                if secure { SecureField(hint, text: value) } else { TextField(hint, text: value).keyboardType(keyboard) }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.s(18))
        }
    }
}

/// Settings as a popup on top of the menu. Changing the server, PIN or name reconnects.
struct SettingsDialog: View {
    let onClose: () -> Void
    let onReconnect: () -> Void
    let onLanguage: () -> Void
    var body: some View {
        ZStack {
            Color(hex: 0xB3000000).ignoresSafeArea()
            SettingsForm(onSaved: { changed in if changed { onReconnect() } else { onClose() } }, onCancel: onClose, onLanguage: onLanguage, title: tr("Settings"))
                .frame(width: 900.dp, height: 640.dp)
                .background(RoundedRectangle(cornerRadius: 18.dp).fill(Palette.panel))
                .overlay(RoundedRectangle(cornerRadius: 18.dp).stroke(Palette.line, lineWidth: 1))
        }
        .onExitCommand(perform: onClose)
    }
}
