import UIKit

struct LaidKey {
    let def: KeyDef
    let path: UIBezierPath
    let center: CGPoint
    let rotation: CGFloat   // 画面上で時計回りを正とするラジアン
    let size: CGSize        // キー中心での幅と高さ（判定とガイド表示に使う）
    let isSector: Bool      // 扇形のくさび形キー
}

struct LayoutResult {
    var keys: [LaidKey]
    var keysBottom: CGFloat
    var height: CGFloat
    var fit: CGFloat
}

enum KeyboardLayout {
    static func mm(_ v: Double) -> CGFloat { CGFloat(v * KeyboardSettings.ptPerMM) }

    private struct Raw {
        var def: KeyDef
        var points: [CGPoint]
        var isSector: Bool
        var center: CGPoint
        var rotation: CGFloat
        var size: CGSize
    }

    private struct Built {
        var keys: [Raw]
        var minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat
        var width: CGFloat { maxX - minX }
    }

    static func make(settings s: KeyboardSettings, width W: CGFloat) -> LayoutResult {
        let avail = W - 2 * mm(s.marginMM)
        var fit: CGFloat = 1
        var built = build(s, W, fit)
        if s.shape != .standard {
            // 画面幅に収まらないときは、キーの幅を縮めて収める
            for _ in 0..<4 where built.width > avail + 0.5 {
                fit *= avail / built.width * 0.995
                built = build(s, W, fit)
            }
        }
        return place(built, s, W, fit)
    }

    private static func build(_ s: KeyboardSettings, _ W: CGFloat, _ fit: CGFloat) -> Built {
        let cols = KeyCatalog.columns
        let n = cols.count
        let g = mm(s.gapMM), m = mm(s.marginMM)
        let oneHand = s.shape != .standard
        let e = CGFloat(s.edgeGrowPercent / 100)

        var colW: [CGFloat] = []
        if oneHand {
            for i in 0..<n {
                let dist = n > 1 ? CGFloat(n - 1 - i) / CGFloat(n - 1) : 0   // 左ほど親指から遠い
                colW.append(mm(s.keyWidthMM) * (1 + e * dist) * fit)
            }
        } else {
            let w = (W - 2 * m - CGFloat(n - 1) * g) / CGFloat(n)
            colW = Array(repeating: w, count: n)
        }
        let rowH: [CGFloat] = (0..<4).map { r in
            mm(s.keyHeightMM) * (1 + (oneHand ? e : 0) * CGFloat(3 - r) / 3)
        }

        var raws: [Raw] = []
        if s.shape != .fan {
            var xs: [CGFloat] = []
            var x: CGFloat = 0
            for w in colW { xs.append(x); x += w + g }
            var ys: [CGFloat] = []
            var y: CGFloat = 0
            for h in rowH { ys.append(y); y += h + g }
            for (i, col) in cols.enumerated() {
                for (r, d) in col.enumerated() {
                    guard let def = d else { continue }
                    var h = rowH[r]
                    if def.rowSpan == 2, r + 1 < 4 { h = rowH[r] + g + rowH[r + 1] }
                    let rect = CGRect(x: xs[i], y: ys[r], width: colW[i], height: h)
                    raws.append(Raw(
                        def: def,
                        points: [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                                 CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)],
                        isSector: false,
                        center: CGPoint(x: rect.midX, y: rect.midY),
                        rotation: 0,
                        size: rect.size))
                }
            }
        } else {
            // 扇形：親指の付け根を中心にした同心円の帯を、共通の角度で区切る
            var inner = [CGFloat](repeating: 0, count: 4)
            var outer = [CGFloat](repeating: 0, count: 4)
            var R = mm(s.fanRadiusMM)
            for r in stride(from: 3, through: 0, by: -1) {
                inner[r] = R
                outer[r] = R + rowH[r]
                R = outer[r] + g
            }
            let refR = (inner[3] + outer[0]) / 2
            let spans = colW.map { ($0 + g) / refR }
            let total = spans.reduce(0, +)
            let center = CGFloat(s.fanAngleDeg) * .pi / 180
            var leftEdge = center + total / 2
            for (i, col) in cols.enumerated() {
                let tl = leftEdge, tr = leftEdge - spans[i]
                leftEdge = tr
                for (r, d) in col.enumerated() {
                    guard let def = d else { continue }
                    let ro = outer[r]
                    var ri = inner[r]
                    if def.rowSpan == 2, r + 1 < 4 { ri = inner[r + 1] }
                    let rc = (ri + ro) / 2, tc = (tl + tr) / 2
                    raws.append(Raw(
                        def: def,
                        points: sector(ri: ri, ro: ro, tr: tr, tl: tl, gap: g),
                        isSector: true,
                        center: CGPoint(x: rc * cos(tc), y: -rc * sin(tc)),
                        rotation: -(tc - .pi / 2),
                        size: CGSize(width: rc * (tl - tr) - g, height: ro - ri)))
                }
            }
        }

        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for k in raws {
            for p in k.points {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
        }
        return Built(keys: raws, minX: minX, maxX: maxX, minY: minY, maxY: maxY)
    }

    /// くさび形キーの輪郭。隙間が均一になるよう、半径ごとに角度の余白を変える。
    private static func sector(ri: CGFloat, ro: CGFloat, tr: CGFloat, tl: CGFloat, gap g: CGFloat) -> [CGPoint] {
        let pad: CGFloat = 1.5   // 角を丸めるための線幅の半分
        let half = g / 2 + pad
        let rIn = ri + pad, rOut = ro - pad
        func edges(_ rho: CGFloat) -> (CGFloat, CGFloat) {
            let d = asin(min(1, half / rho))
            return (tr + d, tl - d)
        }
        let steps = 12
        var pts: [CGPoint] = []
        let (a0, a1) = edges(rIn)
        for k in 0...steps {
            let t = a0 + (a1 - a0) * CGFloat(k) / CGFloat(steps)
            pts.append(CGPoint(x: rIn * cos(t), y: -rIn * sin(t)))
        }
        let (b0, b1) = edges(rOut)
        for k in 0...steps {
            let t = b1 + (b0 - b1) * CGFloat(k) / CGFloat(steps)
            pts.append(CGPoint(x: rOut * cos(t), y: -rOut * sin(t)))
        }
        return pts
    }

    private static func place(_ b: Built, _ s: KeyboardSettings, _ W: CGFloat, _ fit: CGFloat) -> LayoutResult {
        let m = mm(s.marginMM), topPad = mm(1.5)
        let dx = s.shape == .standard ? (W - b.width) / 2 - b.minX : W - m - b.maxX
        let dy = topPad - b.minY
        let keys: [LaidKey] = b.keys.map { raw in
            let pts = raw.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            let path: UIBezierPath
            if raw.isSector {
                path = UIBezierPath()
                path.move(to: pts[0])
                for p in pts.dropFirst() { path.addLine(to: p) }
                path.close()
                path.lineJoinStyle = .round
                path.lineWidth = 3
            } else {
                path = UIBezierPath(roundedRect: CGRect(x: pts[0].x, y: pts[0].y,
                                                        width: raw.size.width, height: raw.size.height),
                                    cornerRadius: 6)
            }
            return LaidKey(def: raw.def, path: path,
                           center: CGPoint(x: raw.center.x + dx, y: raw.center.y + dy),
                           rotation: raw.rotation, size: raw.size, isSector: raw.isSector)
        }
        let keysBottom = topPad + (b.maxY - b.minY)
        return LayoutResult(keys: keys, keysBottom: keysBottom,
                            height: ceil(keysBottom + mm(s.bottomMarginMM)), fit: fit)
    }
}
