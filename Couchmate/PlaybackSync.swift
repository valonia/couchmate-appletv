import Foundation
import UIKit
import TVVLCKit

/// Makes VLC follow the room's state. Called every 250 ms. Small differences are corrected with the playback
/// speed (±8 %), large ones with a seek (with a learned lead to make up for buffering time).
@MainActor
final class PlaybackSync: ObservableObject {
    /// The player on screen. Swapped for the one that buffered the next item when it follows on (see prepareNext).
    private(set) var player = VLCMediaPlayer()
    let videoView = UIView()

    // The next one, opened paused behind the current one so the switch is nearly seamless (like the Android app).
    private var nextPlayer: VLCMediaPlayer?
    private let nextView = UIView() // VLC wants somewhere to draw – never shown
    private var preparedURL: String?
    private var preparedCaptions: String?
    private var reportedNextReady: String?
    @Published private(set) var status = ""
    /// Counts up when the tracks (audio, subtitles) may have changed – the settings panel redraws.
    @Published private(set) var tracksVersion = 0

    var active = true
    /// The address that is played (the plugin's own player choices are added to it).
    var urlFor: (Media) -> String = { $0.url }
    /// The captions to show with it (WebVTT), when CC is on and the plugin has them – else nil.
    var captionsFor: (Media, String) -> String? = { _, _ in nil }

    /// CC was switched on or off: load the one that plays again (with or without captions) where the room is.
    func reloadCaptions() { loadedURL = nil }

    private var loadedURL: String?
    /// Captions to add once the video has opened (VLC only takes them then), and whether this video has them.
    private var pendingCaptions: String?
    private var captionsOn = false
    private var seekedVersion = -1
    private var readyVersion = -1
    private var reportedDuration: String?
    private var cooldownUntil: TimeInterval = 0
    private var lastSeekAt: TimeInterval = 0
    private var correcting = false
    private var livePaused = false
    private var seekLead = 1.5
    private var leadCheck = false
    private var rateWorks: Bool? = nil // nil = not known yet
    private var prefsApplied = false
    private var correctStartAt: TimeInterval = 0
    private var correctStartDrift: Double = 0
    private var lastFineSeekAt: TimeInterval = 0
    private var rate: Float = 1
    private var errorAt: TimeInterval = 0
    private var mutedForLoad = false

    init() {
        videoView.backgroundColor = .black
        player.drawable = videoView
    }

    // Through optionals so it works whatever VLCKit's nullability annotations say.
    var positionSec: Double {
        let t: VLCTime? = player.time
        return Double(t?.intValue ?? 0) / 1000
    }
    var durationSec: Double {
        let m: VLCMedia? = player.media
        let len: VLCTime? = m?.length
        return Double(len?.intValue ?? 0) / 1000
    }

    private func setVolume(_ v: Int32) {
        let audio: VLCAudio? = player.audio
        audio?.volume = v
    }

    // MARK: - audio and subtitles (this Apple TV only)

    struct Track: Identifiable, Hashable {
        let id: Int32
        let name: String
    }

    private func tracks(_ indexes: [Any]?, _ names: [Any]?) -> [Track] {
        let idx = indexes ?? [], nms = names ?? []
        return zip(idx, nms).compactMap { pair in
            guard let id = (pair.0 as? NSNumber)?.int32Value else { return nil }
            return Track(id: id, name: (pair.1 as? String) ?? "\(id)")
        }
    }

    /// Subtitles (without VLC's own "Disable" entry – the panel has its own "Off").
    var subtitleTracks: [Track] { tracks(player.videoSubTitlesIndexes, player.videoSubTitlesNames).filter { $0.id >= 0 } }
    var audioTracks: [Track] { tracks(player.audioTrackIndexes, player.audioTrackNames).filter { $0.id >= 0 } }
    var currentSubtitle: Int32 { player.currentVideoSubTitleIndex }
    var currentAudio: Int32 { player.currentAudioTrackIndex }

    func setSubtitle(_ t: Track?) {
        player.currentVideoSubTitleIndex = t?.id ?? -1
        Prefs.shared.subLang = t?.name ?? "off"
        tracksVersion += 1
    }

    func setAudio(_ t: Track) {
        player.currentAudioTrackIndex = t.id
        Prefs.shared.audioLang = t.name
        tracksVersion += 1
    }

    /// The saved choices, once a new video has opened.
    private func applyTrackPrefs() {
        let p = Prefs.shared
        if captionsOn {
            // CC: the plugin's captions, whatever the saved subtitle choice is.
            if let c = pendingCaptions, let u = URL(string: c) { player.addPlaybackSlave(u, type: .subtitle, enforce: true) }
            pendingCaptions = nil
        } else if p.subLang == "off" { player.currentVideoSubTitleIndex = -1 }
        else if !p.subLang.isEmpty, let t = subtitleTracks.first(where: { $0.name == p.subLang }) { player.currentVideoSubTitleIndex = t.id }
        if !p.audioLang.isEmpty, let t = audioTracks.first(where: { $0.name == p.audioLang }) { player.currentAudioTrackIndex = t.id }
        tracksVersion += 1
    }

    func shutdown() {
        player.stop()
        dropNext()
        loadedURL = nil
    }

    // MARK: - the next one

    /// "Next" known before the end (music, episodes): open it paused in a second player, and tell the server once
    /// it has buffered – it only switches straight on when every app has (otherwise everyone waits as usual).
    private func prepareNext(_ st: RoomState, sync: SyncClient) {
        let early = st.upNext.flatMap { u in u.early && u.media != nil ? u : nil }
        let nextId = early?.item.id ?? st.preparedNext?.item.id
        let next = (early?.media ?? st.preparedNext?.media).flatMap { m in m.live ? nil : m }
        let nextURL = next.map { urlFor($0) }
        if nextURL == preparedURL {
            if let n = nextPlayer, let u = nextURL, let id = nextId, reportedNextReady != u, !n.isPlaying,
               n.state == .paused || n.state == .buffering || n.state == .esAdded {
                let m: VLCMedia? = n.media
                let len: VLCTime? = m?.length
                if (len?.intValue ?? 0) > 0 {
                    reportedNextReady = u
                    sync.nextReady(id)
                }
            }
            return
        }
        dropNext()
        guard let next, let nextURL else { return }
        let p = VLCMediaPlayer()
        p.drawable = nextView
        p.media = makeMedia(nextURL, audio: audioURL(next, nextURL), live: false, startAt: nil, startPaused: true)
        p.play()
        nextPlayer = p
        preparedURL = nextURL
        preparedCaptions = captionsFor(next, nextURL)
    }

    private func dropNext() {
        nextPlayer?.stop()
        nextPlayer = nil
        preparedURL = nil
        preparedCaptions = nil
        reportedNextReady = nil
    }

    /// The next one became the one that plays and it was buffered: it takes over the screen.
    private func takeOverNext() -> Bool {
        guard let n = nextPlayer else { return false }
        let old = player
        old.drawable = nil
        n.drawable = videoView
        player = n
        nextPlayer = nil
        preparedURL = nil
        reportedNextReady = nil
        old.stop()
        return true
    }

    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func tick(_ st: RoomState?, sync: SyncClient) {
        let now = uptime
        guard active else {
            if player.isPlaying { player.pause() }
            return
        }
        guard let st, let media = st.media else {
            if loadedURL != nil { player.stop(); loadedURL = nil }
            dropNext()
            status = tr("Nothing playing")
            return
        }

        let url = urlFor(media)
        if url != loadedURL {
            // Buffered behind the one that just ended: switch to it instead of opening it again.
            let handover = url == preparedURL && !media.live
            let captions = handover ? preparedCaptions : nil
            if handover && takeOverNext() {
                loadedURL = url
                seekedVersion = st.version
                readyVersion = -1
                correcting = false
                livePaused = false
                leadCheck = false
                rateWorks = nil
                prefsApplied = false
                rate = 1
                player.rate = 1
                mutedForLoad = false
                setVolume(100)
                pendingCaptions = captions
                captionsOn = captions != nil
                let start = target(st, sync)
                if start > 1 { seek(start) }
                if !st.paused && sync.serverNow() >= st.refTime { player.play() }
                lastSeekAt = now
                cooldownUntil = now + 2
                return
            }
            dropNext()
            loadedURL = url
            seekedVersion = st.version
            readyVersion = -1
            correcting = false
            livePaused = false
            leadCheck = false
            rateWorks = nil
            prefsApplied = false
            rate = 1
            player.rate = 1
            mutedForLoad = !media.live
            if mutedForLoad { setVolume(0) }
            pendingCaptions = captionsFor(media, url)
            captionsOn = pendingCaptions != nil
            // Joining in the middle of a movie starts right where the others are.
            load(url, audio: audioURL(media, url), live: media.live, startAt: media.live ? nil : target(st, sync) + (st.paused ? 0 : seekLead))
            lastSeekAt = now
            cooldownUntil = now + 2
            return
        }

        if player.state == .error || (player.state == .ended && media.live) {
            status = tr("Playback error – retrying…")
            if now - errorAt > 3 {
                errorAt = now
                load(url, audio: audioURL(media, url), live: media.live, startAt: media.live ? nil : target(st, sync))
            }
            return
        }

        if !prefsApplied, player.state == .playing || player.state == .paused {
            prefsApplied = true
            applyTrackPrefs()
        }
        if !media.live { prepareNext(st, sync: sync) }
        if media.live { tickLive(st, media) } else { tickVod(st, sync, now) }
    }

    /// The separate audio file that goes with the video (e.g. YouTube in HD): the same address with part=audio.
    private func audioURL(_ m: Media, _ url: String) -> String? {
        m.audio && m.type != "hls" ? url + (url.contains("?") ? "&" : "?") + "part=audio" : nil
    }

    private func tickLive(_ st: RoomState, _ media: Media) {
        if st.paused {
            if player.isPlaying { player.pause() }
            livePaused = true
            status = tr("Paused")
            return
        }
        if livePaused {
            // Back to live when someone presses play again.
            livePaused = false
            let url = urlFor(media)
            load(url, audio: audioURL(media, url), live: true, startAt: nil)
            return
        }
        if !player.isPlaying && player.state != .opening && player.state != .buffering { player.play() }
        status = player.state == .opening ? tr("Buffering…") : ""
    }

    private func tickVod(_ st: RoomState, _ sync: SyncClient, _ now: TimeInterval) {
        let pos = positionSec

        // The length, for "next" (once per video – the server may not know it when nobody had to get ready).
        let dur = durationSec
        if dur > 0, reportedDuration != loadedURL, player.state == .playing || player.state == .paused {
            reportedDuration = loadedURL
            sync.duration(dur)
        }

        if st.paused {
            setRate(1)
            correcting = false
            if player.state == .opening {
                status = tr("Loading…")
                return
            }
            if player.isPlaying { player.pause() }
            if seekedVersion != st.version {
                if abs(pos - st.position) > 0.5 { seek(st.position) }
                seekedVersion = st.version
                return
            }
            if st.waiting {
                status = tr("Waiting for everyone to be ready…")
                let positioned = abs(pos - st.position) < 1.5 || now - lastSeekAt > 2.5
                // VLC often stays in "buffering" after a seek or load while paused and never says "paused" – so
                // ready means: the file is open (its length is known), it is not playing and it is in place.
                // (Only waiting for .paused left the others waiting until the server's time limit.)
                let opened = player.state != .opening && player.state != .stopped && player.state != .error
                let loaded = opened && (durationSec > 0 || now - lastSeekAt > 3)
                if readyVersion != st.version, loaded, !player.isPlaying, positioned, now - lastSeekAt > 0.5 {
                    sync.ready(st.version, duration: durationSec)
                    readyVersion = st.version
                }
            } else {
                status = tr("Paused")
            }
            return
        }

        if sync.serverNow() < st.refTime {
            if player.isPlaying { player.pause() }
            status = tr("Starting…")
            return
        }

        let tgt = target(st, sync)
        if !player.isPlaying { player.play() }
        if mutedForLoad {
            setVolume(100)
            mutedForLoad = false
        }
        if now < cooldownUntil { return }

        let d = pos - tgt
        if leadCheck {
            seekLead = min(6, max(0.3, seekLead - d * 0.7))
            leadCheck = false
        }
        if durationSec > 0 && tgt > durationSec {
            status = tr("Ended")
            return
        }
        // Does changing the speed work? With AC3/Dolby passed through it cannot change – then small exact jumps.
        if correcting, rateWorks == nil, now - correctStartAt > 5 {
            rateWorks = abs(d) < abs(correctStartDrift) - 0.1
        }
        let fineSeek = rateWorks == false && abs(d) > 0.3 && now - lastFineSeekAt > 8
        if abs(d) > 2.0 || fineSeek {
            setRate(1)
            correcting = false
            if fineSeek { lastFineSeekAt = now }
            seek(tgt + seekLead)
            cooldownUntil = now + 3
            leadCheck = true
            status = tr("Syncing…")
        } else if rateWorks != false && (abs(d) > 0.4 || (correcting && abs(d) > 0.12)) {
            if !correcting {
                correctStartAt = now
                correctStartDrift = d
            }
            correcting = true
            setRate(Float(min(1.08, max(0.92, 1 - d / 3))))
            status = ""
        } else {
            correcting = false
            setRate(1)
            status = ""
        }
    }

    private func target(_ st: RoomState, _ sync: SyncClient) -> Double {
        if st.paused { return st.position }
        return st.position + Double(max(0, sync.serverNow() - st.refTime)) / 1000
    }

    private func load(_ urlString: String, audio: String?, live: Bool, startAt: Double?) {
        guard let media = makeMedia(urlString, audio: audio, live: live, startAt: startAt, startPaused: false) else { return }
        player.media = media
        player.play()
    }

    private func makeMedia(_ urlString: String, audio: String?, live: Bool, startAt: Double?, startPaused: Bool) -> VLCMedia? {
        guard let url = URL(string: urlString) else { return nil }
        let media = VLCMedia(url: url)
        // Live TV gets a bigger buffer (fewer stutters; nobody notices a few seconds on live). Films and episodes
        // keep a small one so starting and seeking stay quick. (For network streams this is the setting that counts –
        // :live-caching is only for capture devices.)
        media.addOption(live ? ":network-caching=3000" : ":network-caching=1500")
        // Video and audio as two files (e.g. YouTube in HD) – played together.
        if let audio { media.addOption(":input-slave=\(audio)") }
        if let s = startAt, s > 0 { media.addOption(String(format: ":start-time=%.2f", s)) }
        // The next one: opened and buffered, but waiting on its first picture until it is its turn.
        if startPaused { media.addOption(":start-paused") }
        return media
    }

    private func seek(_ sec: Double) {
        player.time = VLCTime(int: Int32(max(0, sec) * 1000))
        lastSeekAt = uptime
    }

    private func setRate(_ r: Float) {
        if abs(r - rate) > 0.004 {
            rate = r
            player.rate = r
        }
    }
}
