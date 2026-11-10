import SwiftUI

// MARK: - focus styles

/// How a focusable thing looks: a row (accent when focused), a card (white when focused), a pill, or plain.
enum FocusLook { case row, card, pill, poster, plain, nav }

struct FocusStyle: ButtonStyle {
    var look: FocusLook
    var selected = false
    var accent = false
    var corner: CGFloat? = nil
    func makeBody(configuration: Configuration) -> some View {
        FocusBody(configuration: configuration, look: look, selected: selected, accent: accent, corner: corner)
    }
}

private struct FocusBody: View {
    let configuration: ButtonStyle.Configuration
    let look: FocusLook
    let selected: Bool
    let accent: Bool
    let corner: CGFloat?
    @Environment(\.isFocused) private var focused

    var body: some View {
        let radius = corner ?? defaultCorner
        configuration.label
            .foregroundStyle(foreground)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(background))
            .overlay {
                if look == .poster && focused {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color.white, lineWidth: 3.dp)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .scaleEffect(focused ? scale : 1)
            .animation(.easeOut(duration: 0.15), value: focused)
            .environment(\.focusedLook, focused)
    }

    private var defaultCorner: CGFloat {
        switch look {
        case .row: return 8.dp
        case .card, .nav: return 12.dp
        case .pill: return 100
        case .poster: return 8.dp
        case .plain: return 0
        }
    }
    private var scale: CGFloat {
        switch look {
        case .card, .pill: return 1.05
        case .poster: return 1.08
        default: return 1
        }
    }
    private var background: Color {
        switch look {
        case .row: return focused ? Palette.accent : selected ? Palette.accentSoft : .clear
        case .card: return focused ? .white : selected ? Palette.accentSoft : Palette.panel
        case .pill: return focused ? .white : selected ? Palette.panelHi : .clear
        case .poster: return Palette.panelHi
        case .nav: return focused ? .white : selected ? Palette.accentSoft : accent ? Color(hex: 0x223D7BFF) : .clear
        case .plain: return .clear
        }
    }
    private var foreground: Color {
        switch look {
        case .row: return focused ? .white : Palette.text
        case .card: return focused ? .black : Palette.text
        case .pill: return focused ? .black : selected ? Palette.text : Palette.dim
        case .nav: return focused ? .black : (selected || accent) ? Palette.text : Palette.dim
        default: return Palette.text
        }
    }
}

/// Whether the button a view sits in has focus (for text that changes colour with it).
private struct FocusedLookKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var focusedLook: Bool {
        get { self[FocusedLookKey.self] }
        set { self[FocusedLookKey.self] = newValue }
    }
}

/// A long press on the remote's centre button (e.g. add to favourites).
extension View {
    @ViewBuilder func onLongPress(_ action: (() -> Void)?) -> some View {
        if let action {
            self.simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in action() })
        } else {
            self
        }
    }
}

/// A focusable row: transparent at rest, accent coloured when focused.
struct FocusRow<Content: View>: View {
    var selected = false
    var height: CGFloat = 56
    var onFocus: (() -> Void)? = nil
    var onLongPress: (() -> Void)? = nil
    let action: () -> Void
    let content: () -> Content
    @FocusState private var focused: Bool

    init(selected: Bool = false, height: CGFloat = 56, onFocus: (() -> Void)? = nil, onLongPress: (() -> Void)? = nil,
         action: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.selected = selected
        self.height = height
        self.onFocus = onFocus
        self.onLongPress = onLongPress
        self.action = action
        self.content = content
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) { content() }
                .padding(.horizontal, 14.dp)
                .frame(maxWidth: .infinity, minHeight: height.dp, maxHeight: height.dp, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(FocusStyle(look: .row, selected: selected))
        .focused($focused)
        .onChange(of: focused) { _, f in if f { onFocus?() } }
        .onLongPress(onLongPress)
    }
}

/// A small "pill" button (tabs, seasons, actions).
struct Pill: View {
    let text: String
    var selected = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text)
                .font(font(16, selected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 14.dp)
                .padding(.vertical, 8.dp)
        }
        .buttonStyle(FocusStyle(look: .pill, selected: selected))
    }
}

// MARK: - images

/// Images, kept in memory so lists scroll smoothly.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()
    private var loading = [String: Task<UIImage?, Never>]()
    init() { cache.countLimit = 400 }

    func cached(_ url: String) -> UIImage? { cache.object(forKey: url as NSString) }

    func load(_ url: String) async -> UIImage? {
        if let img = cached(url) { return img }
        if let t = loading[url] { return await t.value }
        let t = Task<UIImage?, Never> {
            guard let u = URL(string: url), let result = try? await URLSession.shared.data(from: u), let img = UIImage(data: result.0) else { return nil }
            return img
        }
        loading[url] = t
        let img = await t.value
        loading[url] = nil
        if let img { cache.setObject(img, forKey: url as NSString) }
        return img
    }
}

/// An image with fallback text (initials for logos, the title for posters) if it is missing or does not load.
struct Thumb: View {
    let url: String?
    let fallback: String
    var fit = true
    var corner: CGFloat = 6
    @State var image: UIImage?

    var body: some View {
        ZStack {
            Palette.panelHi
            if let image {
                if fit {
                    Image(uiImage: image).resizable().scaledToFit().padding(4.dp)
                } else {
                    GeometryReader { g in
                        Image(uiImage: image).resizable().scaledToFill().frame(width: g.size.width, height: g.size.height).clipped()
                    }
                }
            } else if fit {
                Text(String(fallback.filter { $0.isLetter || $0.isNumber }.prefix(2)).uppercased())
                    .font(font(14, .bold)).foregroundStyle(Palette.faint)
            } else {
                LinearGradient(colors: [Palette.panelHi, Color(hex: 0xFF232A38)], startPoint: .top, endPoint: .bottom)
                Text(cleanTitle(fallback))
                    .font(font(15, .semibold)).foregroundStyle(Palette.dim)
                    .multilineTextAlignment(.center).lineLimit(5).padding(10.dp)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner.dp, style: .continuous))
        .task(id: url) {
            guard let url else { image = nil; return }
            if let c = ImageCache.shared.cached(url) { image = c; return }
            image = nil
            image = await ImageCache.shared.load(url)
        }
    }
}

// MARK: - small pieces

struct ProgressLine: View {
    let fraction: Double
    var color: Color = Palette.accent
    var track: Color = Color(hex: 0x33FFFFFF)
    var height: CGFloat = 3
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(color).frame(width: g.size.width * CGFloat(min(1, max(0, fraction))))
            }
        }
        .frame(height: height.dp)
    }
}

struct LiveBadge: View {
    var body: some View {
        Text("LIVE").font(font(11, .bold)).foregroundStyle(.white)
            .padding(.horizontal, 6.dp).padding(.vertical, 1.dp)
            .background(RoundedRectangle(cornerRadius: 4.dp).fill(Palette.live))
    }
}

func hhmm(_ sec: Int64) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f.string(from: Date(timeIntervalSince1970: TimeInterval(sec)))
}

/// "Today", "Tomorrow" or e.g. "Tuesday 10 November" (in the TV's language).
@MainActor
func dayLabel(_ start: Int64) -> String {
    let d = Date(timeIntervalSince1970: TimeInterval(start))
    let cal = Calendar.current
    if cal.isDateInToday(d) { return tr("Today") }
    if cal.isDateInTomorrow(d) { return tr("Tomorrow") }
    let f = DateFormatter()
    f.locale = I18n.shared.locale
    f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
    return f.string(from: d)
}

/// A clock that updates itself.
struct ClockView: View {
    var size: Double = 22
    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            Text(hhmm(Int64(ctx.date.timeIntervalSince1970))).font(font(size, .light)).foregroundStyle(Palette.text).lineLimit(1)
        }
    }
}

private let avatarColors: [Color] = [0xFF3D7BFF, 0xFFE5484D, 0xFF3DD68C, 0xFFF5C451, 0xFFB57BFF, 0xFF2EC4D6, 0xFFFF8A4C].map { Color(hex: $0) }

/// Java's String.hashCode – so a name gets the same colour here as on Android.
private func javaHash(_ s: String) -> Int32 {
    var h: Int32 = 0
    for u in s.utf16 { h = h &* 31 &+ Int32(u) }
    return h
}

/// A round avatar with an initial, coloured by the name (the same colour for the same person everywhere).
struct Avatar: View {
    let name: String
    let size: CGFloat
    var body: some View {
        let h = UInt32(bitPattern: javaHash(name.lowercased()))
        let color = avatarColors[Int(h % UInt32(avatarColors.count))]
        ZStack {
            Circle().fill(Palette.bg)
            Circle().fill(color).padding(2.dp)
            Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                .font(.system(size: size.dp * 0.45, weight: .bold)).foregroundStyle(.white)
        }
        .frame(width: size.dp, height: size.dp)
    }
}

/// "Bob" · "Bob, Karin" · "Bob, Karin +13"
func viewersText(_ members: [Member]) -> String {
    switch members.count {
    case 0: return ""
    case 1, 2: return members.map(\.name).joined(separator: ", ")
    default: return "\(members[0].name), \(members[1].name) +\(members.count - 2)"
    }
}

struct ViewersChip: View {
    let connected: Bool
    let members: [Member]
    var error: String? = nil
    var body: some View {
        HStack(spacing: 8.dp) {
            if !connected || members.isEmpty {
                Circle().fill(connected ? Palette.green : Palette.live).frame(width: 8.dp, height: 8.dp).padding(.leading, 8.dp)
            } else {
                HStack(spacing: -8.dp) { ForEach(members.prefix(3)) { Avatar(name: $0.name, size: 26) } }
            }
            Text(!connected ? (error ?? tr("Connecting…")) : members.isEmpty ? tr("Connected") : viewersText(members))
                .font(font(14)).foregroundStyle(Palette.dim).lineLimit(1).frame(maxWidth: 220.dp, alignment: .leading)
        }
        .padding(.leading, 6.dp).padding(.trailing, 14.dp).padding(.vertical, 4.dp)
        .background(Capsule().fill(Palette.panel))
    }
}

struct Message: View {
    let text: String
    var error = false
    var body: some View {
        Text(text).font(font(16)).foregroundStyle(error ? Palette.error : Palette.dim).padding(20.dp)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(font(12, .bold)).tracking(1.5.dp).foregroundStyle(Palette.faint)
    }
}

/// Removes typical IPTV tags from titles: "Film [PRE] [2018]" -> "Film".
func cleanTitle(_ name: String) -> String {
    let s = name.replacingOccurrences(of: "\\s*[\\[(][^\\])]*[\\])]", with: "", options: .regularExpression)
        .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    return s.isEmpty ? name : s
}

func compact(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1f M", Double(n) / 1_000_000) }
    if n >= 10_000 { return "\(n / 1000) k" }
    if n >= 1_000 { return String(format: "%.1f k", Double(n) / 1000) }
    return "\(n)"
}

/// A short message from the server or a plugin, shown for a few seconds.
struct NoticeToast: View {
    @ObservedObject var sync: SyncClient
    @State var visible: String?
    var body: some View {
        Group {
            if let v = visible {
                Text(v).font(font(16)).foregroundStyle(Palette.text).lineLimit(2)
                    .padding(.horizontal, 22.dp).padding(.vertical, 10.dp)
                    .background(Capsule().fill(Color(hex: 0xF21A1F29)))
                    .transition(.opacity)
            }
        }
        .onChange(of: sync.notice?.0) { _, _ in
            guard let n = sync.notice, Date().timeIntervalSince(n.0) < 10 else { return }
            withAnimation { visible = n.1 }
            let shown = n.1
            Task { try? await Task.sleep(nanoseconds: 5_000_000_000); if visible == shown { withAnimation { visible = nil } } }
        }
    }
}
