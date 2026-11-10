import SwiftUI

/// The icons in the app: SVG paths in a 24×24 box (plugins send their icons the same way).
enum AppIcon {
    static let liveTv = "M21 6h-7.59l3.29-3.29L16 2l-4 4-4-4-.71.71L10.59 6H3c-1.1 0-2 .89-2 2v12c0 1.1.9 2 2 2h18c1.1 0 2-.9 2-2V8c0-1.11-.9-2-2-2zm0 14H3V8h18v12zM9 10v8l7-4z"
    static let movie = "M18 4l2 4h-3l-2-4h-2l2 4h-3l-2-4H8l2 4H7L5 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V4h-4z"
    static let series = "M4 6H2v14c0 1.1.9 2 2 2h14v-2H4V6zm16-4H8c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm-8 12.5v-9l6 4.5-6 4.5z"
    static let history = "M13 3a9 9 0 0 0-9 9H1l3.89 3.89.07.14L9 12H6c0-3.87 3.13-7 7-7s7 3.13 7 7-3.13 7-7 7c-1.93 0-3.68-.79-4.94-2.06l-1.42 1.42A8.954 8.954 0 0 0 13 21a9 9 0 0 0 0-18zm-1 5v5l4.28 2.54.72-1.21-3.5-2.08V8H12z"
    static let stop = "M6 6h12v12H6z"
    static let star = "M12 17.27L18.18 21l-1.64-7.03L22 9.24l-7.19-.61L12 2 9.19 8.63 2 9.24l5.46 4.73L5.82 21z"
    static let search = "M15.5 14h-.79l-.28-.27A6.471 6.471 0 0 0 16 9.5 6.5 6.5 0 1 0 9.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14z"
    static let settings = "M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58a.49.49 0 0 0 .12-.61l-1.92-3.32a.488.488 0 0 0-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54a.484.484 0 0 0-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58a.49.49 0 0 0-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z"
    static let play = "M8 5v14l11-7z"
    static let bell = "M12 22c1.1 0 2-.9 2-2h-4c0 1.1.89 2 2 2zm6-6v-5c0-3.07-1.64-5.64-4.5-6.32V4c0-.83-.67-1.5-1.5-1.5s-1.5.67-1.5 1.5v.68C7.63 5.36 6 7.92 6 11v5l-2 2v1h16v-1l-2-2z"

    /// An icon by name (views can say { type: 'icon', name: 'star' }).
    static func named(_ name: String) -> String? {
        switch name {
        case "bell": return bell
        case "star": return star
        case "search": return search
        case "play": return play
        case "history": return history
        case "live": return liveTv
        case "movie": return movie
        case "series": return series
        default: return nil
        }
    }

    static func forCore(_ core: String?) -> String {
        switch core {
        case "favorites": return star
        case "history": return history
        default: return liveTv
        }
    }
}

/// Draws an SVG path (24×24) in the current foreground colour.
struct PathIcon: View {
    let path: String?
    var size: CGFloat = 24
    var body: some View {
        SVGShape(svg: path ?? AppIcon.liveTv).frame(width: size.dp, height: size.dp)
    }
}

struct SVGShape: Shape {
    let svg: String
    func path(in rect: CGRect) -> Path {
        let p = SVGPath.parse(svg) ?? SVGPath.parse(AppIcon.liveTv) ?? Path()
        let s = min(rect.width, rect.height) / 24
        return p.applying(CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: rect.minX, ty: rect.minY))
    }
}

/// A small SVG path parser: M L H V C S Q T A Z, absolute and relative. Results are kept.
enum SVGPath {
    nonisolated(unsafe) private static var cache = [String: Path]()
    private static let lock = NSLock()

    static func parse(_ d: String) -> Path? {
        lock.lock(); defer { lock.unlock() }
        if let p = cache[d] { return p }
        guard let p = build(d) else { return nil }
        cache[d] = p
        return p
    }

    private static func tokens(_ d: String) -> [String] {
        var out = [String]()
        var cur = ""
        var prev: Character = " "
        for ch in d {
            if ch.isLetter && ch != "e" && ch != "E" {
                if !cur.isEmpty { out.append(cur); cur = "" }
                out.append(String(ch))
            } else if ch == "," || ch == " " || ch == "\n" || ch == "\t" {
                if !cur.isEmpty { out.append(cur); cur = "" }
            } else if ch == "-" && !cur.isEmpty && prev != "e" && prev != "E" {
                out.append(cur); cur = "-"
            } else if ch == "." && cur.contains(".") && !cur.contains("e") {
                out.append(cur); cur = "."
            } else {
                cur.append(ch)
            }
            prev = ch
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private static func build(_ d: String) -> Path? {
        var t = tokens(d)
        var i = 0
        var path = Path()
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastCtrl: CGPoint? = nil, lastQuad: CGPoint? = nil
        var cmd: Character = "M"

        func num() -> CGFloat? {
            guard i < t.count, let v = Double(t[i]) else { return nil }
            i += 1
            return CGFloat(v)
        }
        /// An arc flag: "0"/"1", possibly glued to what follows ("011" = 0, then "11").
        func flag() -> Bool {
            guard i < t.count else { return false }
            let s = t[i]
            if s.count > 1, let f = s.first, f == "0" || f == "1" {
                t[i] = String(s.dropFirst())
                return f == "1"
            }
            i += 1
            return s == "1"
        }

        var steps = 0
        while i < t.count {
            steps += 1
            if steps > 20000 { return nil }
            if let c = t[i].first, t[i].count == 1, c.isLetter { cmd = c; i += 1; continue }
            let rel = cmd.isLowercase
            let o = rel ? cur : CGPoint.zero
            switch cmd.uppercased() {
            case "M":
                guard let x = num(), let y = num() else { return path }
                cur = CGPoint(x: o.x + x, y: o.y + y); start = cur
                path.move(to: cur)
                cmd = rel ? "l" : "L"
                lastCtrl = nil; lastQuad = nil
            case "L":
                guard let x = num(), let y = num() else { return path }
                cur = CGPoint(x: o.x + x, y: o.y + y); path.addLine(to: cur)
                lastCtrl = nil; lastQuad = nil
            case "H":
                guard let x = num() else { return path }
                cur = CGPoint(x: (rel ? cur.x : 0) + x, y: cur.y); path.addLine(to: cur)
                lastCtrl = nil; lastQuad = nil
            case "V":
                guard let y = num() else { return path }
                cur = CGPoint(x: cur.x, y: (rel ? cur.y : 0) + y); path.addLine(to: cur)
                lastCtrl = nil; lastQuad = nil
            case "C":
                guard let x1 = num(), let y1 = num(), let x2 = num(), let y2 = num(), let x = num(), let y = num() else { return path }
                let c1 = CGPoint(x: o.x + x1, y: o.y + y1), c2 = CGPoint(x: o.x + x2, y: o.y + y2)
                cur = CGPoint(x: o.x + x, y: o.y + y)
                path.addCurve(to: cur, control1: c1, control2: c2)
                lastCtrl = c2; lastQuad = nil
            case "S":
                guard let x2 = num(), let y2 = num(), let x = num(), let y = num() else { return path }
                let p = cur
                let c1 = lastCtrl.map { CGPoint(x: 2 * p.x - $0.x, y: 2 * p.y - $0.y) } ?? p
                let c2 = CGPoint(x: o.x + x2, y: o.y + y2)
                cur = CGPoint(x: o.x + x, y: o.y + y)
                path.addCurve(to: cur, control1: c1, control2: c2)
                lastCtrl = c2; lastQuad = nil
            case "Q":
                guard let x1 = num(), let y1 = num(), let x = num(), let y = num() else { return path }
                let c = CGPoint(x: o.x + x1, y: o.y + y1)
                cur = CGPoint(x: o.x + x, y: o.y + y)
                path.addQuadCurve(to: cur, control: c)
                lastQuad = c; lastCtrl = nil
            case "T":
                guard let x = num(), let y = num() else { return path }
                let p = cur
                let c = lastQuad.map { CGPoint(x: 2 * p.x - $0.x, y: 2 * p.y - $0.y) } ?? p
                cur = CGPoint(x: o.x + x, y: o.y + y)
                path.addQuadCurve(to: cur, control: c)
                lastQuad = c; lastCtrl = nil
            case "A":
                guard let rx = num(), let ry = num(), let rot = num() else { return path }
                let large = flag()
                let sweep = flag()
                guard let x = num(), let y = num() else { return path }
                let end = CGPoint(x: o.x + x, y: o.y + y)
                addArc(&path, from: cur, to: end, rx: rx, ry: ry, angle: rot, large: large, sweep: sweep)
                cur = end
                lastCtrl = nil; lastQuad = nil
            case "Z":
                path.closeSubpath(); cur = start
                lastCtrl = nil; lastQuad = nil
            default:
                i += 1
            }
        }
        return path
    }

    /// An elliptical arc as cubic curves (SVG's endpoint form, converted to centre form).
    private static func addArc(_ path: inout Path, from p0: CGPoint, to p1: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat, angle: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 || p0 == p1 { path.addLine(to: p1); return }
        let phi = angle * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosP * dx + sinP * dy, y1 = -sinP * dx + cosP * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let numer = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denom = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef: CGFloat = denom == 0 ? 0 : sqrt(max(0, numer / denom))
        if large == sweep { coef = -coef }
        let cx1 = coef * rx * y1 / ry, cy1 = -coef * ry * x1 / rx
        let cx = cosP * cx1 - sinP * cy1 + (p0.x + p1.x) / 2
        let cy = sinP * cx1 + cosP * cy1 + (p0.y + p1.y) / 2
        func ang(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta1 = ang(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var dTheta = ang((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
        if sweep && dTheta < 0 { dTheta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(dTheta) / (.pi / 2))))
        let delta = dTheta / CGFloat(segments)
        let k: CGFloat = 4.0 / 3.0 * tan(delta / 4)
        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: cx + rx * p.x * cosP - ry * p.y * sinP, y: cy + rx * p.x * sinP + ry * p.y * cosP)
        }
        var a = theta1
        for _ in 0..<segments {
            let cosT = cos(a), sinT = sin(a), cosT2 = cos(a + delta), sinT2 = sin(a + delta)
            let e1 = CGPoint(x: cosT - k * sinT, y: sinT + k * cosT)
            let e2 = CGPoint(x: cosT2 + k * sinT2, y: sinT2 - k * cosT2)
            let e3 = CGPoint(x: cosT2, y: sinT2)
            path.addCurve(to: map(e3), control1: map(e1), control2: map(e2))
            a += delta
        }
    }
}
