import Foundation

/// Settings on this Apple TV.
final class Prefs {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    var serverUrl: String { get { d.string(forKey: "server") ?? "" } set { d.set(newValue, forKey: "server") } }
    var pin: String { get { d.string(forKey: "pin") ?? "" } set { d.set(newValue, forKey: "pin") } }
    var name: String { get { d.string(forKey: "name") ?? "" } set { d.set(newValue, forKey: "name") } }
    /// Language: "auto" (the TV's language) or "en".
    var language: String { get { d.string(forKey: "language") ?? "auto" } set { d.set(newValue, forKey: "language") } }
    /// Subtitle language ("off" = off, "" = the file's default) and audio language – this TV only.
    var subLang: String { get { d.string(forKey: "subLang") ?? "" } set { d.set(newValue, forKey: "subLang") } }
    var audioLang: String { get { d.string(forKey: "audioLang") ?? "" } set { d.set(newValue, forKey: "audioLang") } }
    /// CC: the captions a plugin gives (e.g. YouTube) – on or off for everything, this TV only.
    var cc: Bool { get { d.bool(forKey: "cc") } set { d.set(newValue, forKey: "cc") } }
    /// Live streams: show the chat.
    var chatOn: Bool { get { d.bool(forKey: "chatOn") } set { d.set(newValue, forKey: "chatOn") } }
    /// A plugin's own player choices (type "choice"), per plugin and choice.
    func pluginOpt(_ plugin: String, _ id: String) -> String? { d.string(forKey: "opt.\(plugin).\(id)") }
    func setPluginOpt(_ plugin: String, _ id: String, _ value: String) { d.set(value, forKey: "opt.\(plugin).\(id)") }

    var isConfigured: Bool { !serverUrl.isEmpty && !name.isEmpty }
}
