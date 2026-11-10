import Foundation
import SwiftUI

/// The app's name – shown in the menu and on the setup screen.
let appName = "Couchmate"

/// Translation. Everything in the app is written in English and passed through `tr`. The Couchmate server
/// translates it into the TV's language and every translation is kept on the TV, so nothing is translated twice.
/// Until a translation is there, the English text is shown. Text from plugins arrives already translated.
@MainActor
final class I18n: ObservableObject {
    static let shared = I18n()

    /// nil = English (nothing to translate).
    @Published private(set) var lang: String?
    @Published private var dict: [String: String] = [:]
    private var pending = [String]()
    private var pendingSet = Set<String>()
    private var tries = [String: Int]()
    private let store = UserDefaults(suiteName: "couchmate_i18n") ?? .standard

    /// The language to use: the TV's own language, unless the user chose English.
    static func resolve(_ pref: String) -> String? {
        if pref == "en" { return nil }
        let sys = (Locale.preferredLanguages.first.map { Locale(identifier: $0).language.languageCode?.identifier ?? "" } ?? "").lowercased()
        return sys.isEmpty || sys == "en" ? nil : sys
    }

    func configure(_ pref: String) {
        let l = I18n.resolve(pref)
        dict = [:]
        pending = []; pendingSet = []; tries = [:]
        if let l, let s = store.string(forKey: l), let data = s.data(using: .utf8), let o = parseJSON(data) as? [String: String] {
            dict = o
        }
        lang = l
    }

    /// A translation was corrected on the server: forget what this TV kept and ask again.
    func invalidate(_ language: String?) {
        if let language, language != lang { return }
        pending = []; pendingSet = []; tries = [:]
        dict = [:]
        if let l = lang { store.removeObject(forKey: l) }
    }

    /// The server's fingerprint of its corrected texts – when it changes, what this TV kept is thrown away.
    func checkVersion(_ language: String?, _ version: String) -> Bool {
        guard let l = lang, language == l, !version.isEmpty else { return false }
        let key = "version:\(l)"
        if store.string(forKey: key) == version { return false }
        invalidate(l)
        store.set(version, forKey: key)
        return true
    }

    var locale: Locale { Locale(identifier: lang ?? "en") }

    func translate(_ text: String) -> String {
        guard lang != nil, !text.isEmpty else { return text }
        if let t = dict[text] { return t }
        if pendingSet.insert(text).inserted { pending.append(text) }
        return text
    }

    /// Sends texts without a translation to the server in batches, while the app runs.
    func pump(_ api: Api) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let l = lang, !pending.isEmpty else { continue }
            let batch = pending
            pending = []; pendingSet = []
            guard let res = try? await api.translate(batch, lang: l) else {
                for t in batch where pendingSet.insert(t).inserted { pending.append(t) }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                continue
            }
            if lang != l { continue }
            let (translations, complete) = res
            var retry = [String]()
            var next = dict
            for t in batch {
                if let v = translations[t], complete || v != t { next[t] = v }
                else { tries[t, default: 0] += 1; if tries[t]! < 20 { retry.append(t) } }
            }
            dict = next
            store.set(toJSONString(next), forKey: l)
            if !retry.isEmpty {
                // The server translates in the background – ask again soon.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                for t in retry where pendingSet.insert(t).inserted { pending.append(t) }
            }
        }
    }
}

/// English text, translated into the TV's language. Placeholders: tr("{n} connected", ["n": 3]).
/// Never pass names or content (channel names, titles) through here – only the app's own words.
@MainActor
func tr(_ text: String, _ vars: [String: Any] = [:]) -> String {
    var s = I18n.shared.translate(text)
    for (k, v) in vars { s = s.replacingOccurrences(of: "{\(k)}", with: "\(v)") }
    return s
}
