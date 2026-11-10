import SwiftUI

/// What happens when an item is chosen: play it for everyone, or open its page.
typealias ItemOpener = (Item) -> Void

/// A 16:9 card: picture with LIVE and viewers, title and subtitle (streams, videos).
struct LandscapeCard: View {
    let item: Item
    let api: Api
    var playing = false
    var favorite = false
    let onClick: () -> Void
    var onLongPress: (() -> Void)? = nil

    var body: some View {
        Button(action: onClick) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    Thumb(url: api.abs(item.image), fallback: item.subtitle ?? item.title, fit: false, corner: 12)
                    HStack(spacing: 6.dp) {
                        if item.live { LiveBadge() }
                        if let v = item.viewers {
                            Text(tr("{n} viewers", ["n": compact(v)])).font(.s(11)).foregroundStyle(.white)
                                .padding(.horizontal, 6.dp).padding(.vertical, 1.dp)
                                .background(RoundedRectangle(cornerRadius: 4.dp).fill(Color(hex: 0xB3000000)))
                        }
                    }
                    .padding(8.dp)
                    if favorite {
                        Text("★").font(.s(15)).foregroundStyle(Palette.gold)
                            .padding(.horizontal, 7.dp).padding(.vertical, 2.dp)
                            .background(Capsule().fill(Color(hex: 0xB30A0C10)))
                            .padding(6.dp)
                            .frame(maxWidth: .infinity, alignment: .topTrailing)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                // Streams: the channel above the stream's title; anything else: the title above its subtitle.
                let pair: (String, String?) = item.live && item.subtitle != nil ? (item.subtitle!, item.title) : (item.title, item.subtitle)
                VStack(alignment: .leading, spacing: 2.dp) {
                    Text(pair.0).font(.s(15, .semibold)).lineLimit(1)
                    Text(pair.1 ?? " ").font(.s(13)).lineLimit(2)
                }
                .padding(.horizontal, 12.dp).padding(.vertical, 10.dp)
            }
            .frame(width: 300.dp)
        }
        .buttonStyle(FocusStyle(look: .card, selected: playing))
        .onLongPress(onLongPress)
    }
}

/// A poster (movies, series): cover, ★ when a favourite, NEW when there are new episodes, title below.
struct PosterCard: View {
    let title: String
    let image: String?
    var favorite = false
    var newCount = 0
    var caption: String? = nil
    var width: CGFloat = 128
    let onClick: () -> Void
    var onLongPress: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onClick) {
                ZStack {
                    Thumb(url: image, fallback: title, fit: false, corner: 8)
                    if favorite {
                        Text("★").font(.s(15)).foregroundStyle(Palette.gold)
                            .padding(.horizontal, 7.dp).padding(.vertical, 2.dp)
                            .background(Capsule().fill(Color(hex: 0xB30A0C10)))
                            .padding(6.dp)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    if newCount > 0 {
                        Text(newCount == 1 ? tr("NEW") : tr("{n} NEW", ["n": newCount])).font(.s(11, .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6.dp).padding(.vertical, 2.dp)
                            .background(RoundedRectangle(cornerRadius: 4.dp).fill(Palette.accent))
                            .padding(6.dp)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
                .aspectRatio(2 / 3, contentMode: .fit)
            }
            .buttonStyle(FocusStyle(look: .poster))
            .onLongPress(onLongPress)
            if let caption {
                Text(caption).font(.s(12, .semibold)).foregroundStyle(Palette.accent).lineLimit(1).padding(.top, 6.dp)
            }
            Text(title).font(.s(13)).foregroundStyle(Palette.dim).lineLimit(1).padding(.top, 6.dp)
        }
        .frame(width: width.dp)
    }
}

/// A compact channel card for rows (search, favourites).
struct ChannelCard: View {
    let item: Item
    let api: Api
    var favorite = false
    let onClick: () -> Void
    var onLongPress: (() -> Void)? = nil
    var body: some View {
        FocusRow(height: 76, onLongPress: onLongPress, action: onClick) {
            Thumb(url: api.abs(item.image), fallback: item.title).frame(width: 80.dp, height: 46.dp)
            Spacer().frame(width: 14.dp)
            VStack(alignment: .leading) {
                Text(item.title).font(.s(16, .medium)).lineLimit(1)
                if let s = item.subtitle { Text(s).font(.s(13)).foregroundStyle(Palette.dim).lineLimit(1) }
            }
            Spacer(minLength: 0)
            if favorite { Text("★").font(.s(15)).foregroundStyle(Palette.gold) }
        }
        .frame(width: 300.dp)
        .background(RoundedRectangle(cornerRadius: 8.dp).fill(Palette.panel))
    }
}

/// The right card for a row's style: landscape | poster | square | channels.
struct ItemCard: View {
    let item: Item
    let style: String
    let api: Api
    @ObservedObject var sync: SyncClient
    let opener: ItemOpener
    var body: some View {
        let fav = sync.favorites.first { $0.key == item.key }
        let longPress: (() -> Void)? = item.favorite ? { sync.toggleFavorite(item) } : nil
        switch style {
        case "poster", "square":
            PosterCard(title: cleanTitle(item.title), image: api.abs(item.image), favorite: fav != nil, newCount: fav?.newCount ?? 0,
                       caption: fav.flatMap { f in f.newCount > 0 ? f.newLabel.map { tr("New: {episode}", ["episode": $0]) } : nil },
                       onClick: { opener(item) }, onLongPress: longPress)
        case "channels":
            ChannelCard(item: item, api: api, favorite: fav != nil, onClick: { opener(item) }, onLongPress: longPress)
        default:
            LandscapeCard(item: item, api: api, playing: item.key == sync.state?.media?.key, favorite: fav != nil, onClick: { opener(item) }, onLongPress: longPress)
        }
    }
}

/// A titled row of cards (search results).
struct CardRow: View {
    let title: String
    let row: ItemRow
    let api: Api
    @ObservedObject var sync: SyncClient
    let opener: ItemOpener
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(title).font(.s(20, .bold))
                Text("  \(row.items.count)").font(.s(20)).foregroundStyle(Palette.faint)
            }
            .padding(.leading, 12.dp).padding(.bottom, 8.dp)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16.dp) {
                    let keys = uniqueKeys(row.items)
                    ForEach(Array(row.items.enumerated()), id: \.offset) { i, item in
                        ItemCard(item: item, style: row.style, api: api, sync: sync, opener: opener).id(keys[i])
                    }
                }
                .padding(.horizontal, 12.dp).padding(.vertical, 10.dp)
            }
            .scrollClipDisabled()
        }
    }
}
