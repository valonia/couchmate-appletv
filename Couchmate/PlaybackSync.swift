import Foundation
import UIKit
import TVVLCKit

/// Makes VLC follow the room's state. Called every 250 ms. Small differences are corrected with the playback
/// speed (±8 %), large ones with a seek (with a learned lead to make up for buffering time).
@MainActor
final class PlaybackSync: ObservableObject {
    let player = VLCMediaPlayer()
    let videoView = UIView()
    @Published private(set) var status = ""
    /// Counts up when the tracks (audio, subtitles) may have changed – the settings panel redraws.
    @Published private(set) var tracksVersion = 0

    var active = true
    /// The address that is played (the plugin's own player choices are added to it).
    var urlFor: (Media) -> String = { $0.url }

    private var loadedURL: String?
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
        if p.subLang == "off" { player.currentVideoSubTitleIndex = -1 }
        else if !p.subLang.isEmpty, let t = subtitleTracks.first(where: { $0.name == p.subLang }) { player.currentVideoSubTitleIndex = t.id }
        if !p.audioLang.isEmpty, let t = audioTracks.first(where: { $0.name == p.audioLang }) { player.currentAudioTrackIndex = t.id }
        tracksVersion += 1
    }

    func shutdown() {
        player.stop()
        loadedURL = nil
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
            status = tr("Nothing playing")
            return
        }

        let url = urlFor(media)
        if url != loadedURL {
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
            // Joining in the middle of a movie starts right where the others are.
            load(url, audio: audioURL(media, url), startAt: media.live ? nil : target(st, sync) + (st.paused ? 0 : seekLead))
            lastSeekAt = now
            cooldownUntil = now + 2
            return
        }

        if player.state == .error || (player.state == .ended && media.live) {
            status = tr("Playback error – retrying…")
            if now - errorAt > 3 {
                errorAt = now
                load(url, audio: audioURL(media, url), startAt: media.live ? nil : target(st, sync))
            }
            return
        }

        if !prefsApplied, player.state == .playing || player.state == .paused {
            prefsApplied = true
            applyTrackPrefs()
        }
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
            load(url, audio: audioURL(media, url), startAt: nil)
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
                if readyVersion != st.version, player.state == .paused, positioned, now - lastSeekAt > 0.5 {
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

    private func load(_ urlString: String, audio: String?, startAt: Double?) {
        guard let url = URL(string: urlString) else { return }
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=1500")
        // Video and audio as two files (e.g. YouTube in HD) – played together.
        if let audio { media.addOption(":input-slave=\(audio)") }
        if let s = startAt, s > 0 { media.addOption(String(format: ":start-time=%.2f", s)) }
        player.media = media
        player.play()
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
