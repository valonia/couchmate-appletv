import SwiftUI

// Skeletons: grey shapes where the content will be, pulsing gently while it loads – calmer than a "Loading…"
// text, even when it only shows for a moment. Each one takes the shape of what is coming (rows, cards, posters).

private let bone = Color.white.opacity(0.12)

/// A gentle pulse for everything inside it.
private struct Pulse: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0.45)
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true } }
    }
}

private struct Bone: View {
    var radius: CGFloat = 8
    var body: some View { RoundedRectangle(cornerRadius: radius.dp).fill(bone) }
}

/// Rows like a list of channels, episodes or history: a picture and two lines of text.
struct SkeletonRows: View {
    var count = 6
    var height: CGFloat = 64
    var picture = true
    var body: some View {
        VStack(spacing: 6.dp) {
            ForEach(0..<count, id: \.self) { i in
                HStack(spacing: 16.dp) {
                    if picture { Bone(radius: 6).frame(width: height.dp * 1.5, height: (height - 18).dp) }
                    VStack(alignment: .leading, spacing: 8.dp) {
                        // Slightly different lengths, so it looks like text.
                        GeometryReader { g in Bone(radius: 4).frame(width: g.size.width * [0.55, 0.4, 0.65, 0.48][i % 4]) }.frame(height: 14.dp)
                        GeometryReader { g in Bone(radius: 4).frame(width: g.size.width * [0.3, 0.36, 0.25, 0.33][i % 4]) }.frame(height: 10.dp)
                    }
                }
                .frame(height: height.dp)
                .padding(.horizontal, 14.dp)
            }
        }
        .modifier(Pulse())
    }
}

/// A row of cards (16:9) or posters (2:3) – what a horizontal list will hold.
struct SkeletonCards: View {
    var count = 6
    var width: CGFloat = 240
    var aspect: CGFloat = 16.0 / 9.0
    var body: some View {
        HStack(spacing: 16.dp) {
            ForEach(0..<count, id: \.self) { _ in Bone(radius: 12).frame(width: width.dp, height: width.dp / aspect) }
        }
        .modifier(Pulse())
    }
}

/// A wall of posters, like Movies or Series.
struct SkeletonGrid: View {
    var rows = 2
    var columns = 6
    var aspect: CGFloat = 2.0 / 3.0
    var body: some View {
        VStack(spacing: 16.dp) {
            ForEach(0..<rows, id: \.self) { _ in
                HStack(spacing: 16.dp) {
                    ForEach(0..<columns, id: \.self) { _ in Bone().aspectRatio(aspect, contentMode: .fit) }
                }
            }
        }
        .modifier(Pulse())
    }
}

/// A whole page that is on its way: a heading, two rows of cards.
struct SkeletonPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18.dp) {
            Bone(radius: 6).frame(width: 260.dp, height: 30.dp)
            ForEach(0..<2, id: \.self) { _ in
                Bone(radius: 4).frame(width: 180.dp, height: 16.dp)
                HStack(spacing: 16.dp) {
                    ForEach(0..<5, id: \.self) { _ in Bone(radius: 12).frame(width: 260.dp, height: 260.dp * 9 / 16) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 8.dp).padding(.top, 12.dp)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(Pulse())
    }
}

/// A couple of lines of text (a small block whose data is on its way).
struct SkeletonLines: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8.dp) {
            GeometryReader { g in Bone(radius: 4).frame(width: g.size.width * 0.6) }.frame(height: 12.dp)
            GeometryReader { g in Bone(radius: 4).frame(width: g.size.width * 0.4) }.frame(height: 12.dp)
        }
        .modifier(Pulse())
    }
}
