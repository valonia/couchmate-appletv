import SwiftUI

/// A row in a channel list: number, logo, name, the programme on now and its progress.
struct ChannelRow: View {
    let item: Item
    let epg: [Program]?
    let now: Int64
    let playing: Bool
    let iconUrl: String?
    var favorite = false
    var onFocus: (() -> Void)? = nil
    var onLongPress: (() -> Void)? = nil
    let onClick: () -> Void

    var body: some View {
        let prog = epg?.now(now)
        FocusRow(selected: playing, height: 64, onFocus: onFocus, onLongPress: onLongPress, action: onClick) {
            Text(item.number.map(String.init) ?? "").font(font(15)).foregroundStyle(Palette.dim).frame(width: 48.dp, alignment: .leading)
            Thumb(url: iconUrl, fallback: item.title).frame(width: 64.dp, height: 38.dp)
            Spacer().frame(width: 14.dp)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8.dp) {
                    Text(item.title).font(font(17, .medium)).lineLimit(1)
                    if favorite { Text("★").font(font(14)).foregroundStyle(Palette.gold) }
                    if playing { Text("▶").font(font(13)) }
                }
                if let prog {
                    Text("\(hhmm(prog.start))  \(prog.title)").font(font(14)).opacity(0.7).lineLimit(1)
                    ProgressLine(fraction: prog.progress(now), color: Color(hex: 0xCCFFFFFF), track: Color(hex: 0x22FFFFFF)).padding(.top, 4.dp)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// The channel's schedule next to a channel (favourites): on now and coming up. OK on a coming programme sets a
/// reminder for the whole room; OK on the one on now plays the channel.
struct ChannelGuide: View {
    let item: Item
    let shortEpg: [Program]?
    let api: Api
    @ObservedObject var sync: SyncClient
    @State var guide: [Program]?

    var body: some View {
        let now = nowSec()
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16.dp) {
                Thumb(url: api.abs(item.image), fallback: item.title, corner: 8).frame(width: 120.dp, height: 68.dp)
                VStack(alignment: .leading) {
                    HStack(spacing: 8.dp) {
                        if let n = item.number { Text("\(n)").font(font(16)).foregroundStyle(Palette.dim) }
                        LiveBadge()
                    }
                    Text(item.title).font(font(21, .bold)).lineLimit(2)
                }
            }
            .padding(.bottom, 14.dp)
            let programs = (guide ?? shortEpg ?? []).filter { $0.end > now }
            if programs.isEmpty {
                Text(tr("No programme information")).font(font(16)).foregroundStyle(Palette.faint)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2.dp) {
                        ForEach(Array(programs.enumerated()), id: \.offset) { i, p in
                            if i == 0 || dayLabel(programs[i - 1].start) != dayLabel(p.start) {
                                SectionLabel(text: dayLabel(p.start)).padding(.leading, 6.dp).padding(.top, 10.dp).padding(.bottom, 4.dp)
                            }
                            GuideRow(p: p, now: now, reminder: sync.reminders.first { $0.key == reminderKey(item.plugin, item.id, p.start) }) {
                                if p.isNow(now) { sync.load(item) } else { sync.toggleReminder(item, p) }
                            }
                        }
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 22.dp, leading: 22.dp, bottom: 16.dp, trailing: 14.dp))
        .background(RoundedRectangle(cornerRadius: 12.dp).fill(Palette.panel))
        .task(id: item.key) {
            try? await Task.sleep(nanoseconds: 350_000_000) // wait until browsing stops
            guide = try? await api.guide(item.plugin, item.id)
        }
    }
}

private struct GuideRow: View {
    let p: Program
    let now: Int64
    let reminder: Reminder?
    let onClick: () -> Void
    var body: some View {
        let live = p.isNow(now)
        FocusRow(selected: live || reminder != nil, height: 64, action: onClick) {
            VStack(alignment: .leading) {
                Text(hhmm(p.start)).font(font(16, .bold))
                Text("– \(hhmm(p.end))").font(font(12)).foregroundStyle(Palette.faint)
            }
            .frame(width: 70.dp, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8.dp) {
                    if live {
                        Text(tr("ON NOW")).font(font(10, .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6.dp).padding(.vertical, 1.dp)
                            .background(RoundedRectangle(cornerRadius: 4.dp).fill(Palette.live))
                    }
                    Text(p.title).font(font(15, .medium)).lineLimit(1)
                }
                if live {
                    ProgressLine(fraction: p.progress(now)).padding(.top, 6.dp)
                } else if let r = reminder {
                    Text(r.addedBy.map { tr("Reminder · by {name}", ["name": $0]) } ?? tr("Reminder")).font(font(12)).foregroundStyle(Palette.gold).lineLimit(1)
                } else if let d = p.description {
                    Text(d).font(font(12)).foregroundStyle(Palette.dim).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if !live {
                PathIcon(path: AppIcon.bell, size: 20).foregroundStyle(reminder != nil ? Palette.gold : Color(hex: 0x55FFFFFF))
            }
        }
    }
}

/// "Reminder: X starts 21:00 – switching channel in 23 s". In the player it is controlled with OK/Menu; in the
/// menu the card has its own buttons (`interactive`).
struct ReminderCard: View {
    let reminder: PendingReminder
    let secondsLeft: Int64
    let interactive: Bool
    let onNow: () -> Void
    let onCancel: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 16.dp) {
            ZStack {
                Circle().fill(Color(hex: 0x33F5C451))
                PathIcon(path: AppIcon.bell, size: 26).foregroundStyle(Palette.gold)
            }
            .frame(width: 48.dp, height: 48.dp)
            VStack(alignment: .leading, spacing: 0) {
                Text(tr("REMINDER  ·  SWITCHING CHANNEL IN {n} S", ["n": secondsLeft])).font(font(12, .bold)).tracking(1.dp).foregroundStyle(Palette.gold)
                Text(reminder.title).font(font(18, .semibold)).lineLimit(1).padding(.top, 4.dp)
                Text(tr("Starts {time} on {channel}", ["time": hhmm(reminder.start), "channel": reminder.channelTitle])).font(font(15)).foregroundStyle(Palette.dim).lineLimit(1)
                if interactive {
                    HStack(spacing: 8.dp) {
                        Pill(text: tr("Switch now"), selected: true, action: onNow)
                        Pill(text: tr("Cancel"), action: onCancel)
                    }
                    .padding(.top, 10.dp)
                } else {
                    Text(tr("OK switch now   ·   Menu cancel")).font(font(13)).foregroundStyle(Palette.faint).padding(.top, 10.dp)
                }
            }
        }
        .padding(18.dp)
        .frame(width: 560.dp, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14.dp).fill(Color(hex: 0xF21A1F29)))
    }
}
