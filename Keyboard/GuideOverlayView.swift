import UIKit

/// 数字に書き換えて見せる1つのキー
struct GuideCell {
    let path: UIBezierPath
    let center: CGPoint
    let rotation: CGFloat
    let text: String
    let selected: Bool
    let fontSize: CGFloat
    let isSector: Bool
}

struct FlickGuide {
    let center: CGPoint
    let size: CGSize
    let rotation: CGFloat
    let chars: [String]
    let selected: FlickDirection
    /// 方向ごとの表示位置（キー何個分か）。省略すると十字に並べる
    var offsets: [CGPoint]? = nil
    /// true なら選んでいる間も十字全体を出す（数字キー）。false ならiOS標準と同じく、選んだ方向だけ吹き出しで出す
    var keepCross = false
    /// true なら画面内に収めるための位置の調整をしない（呼び出し側で済ませている）
    var fixedPosition = false
    /// 数字の入力：かなキーの上に重ねて、数字に書き換えて見せるキー。指定すると十字ではなくこれを描く
    var cells: [GuideCell]? = nil
}

/// フリック中のガイドを、変換候補の帯の上にも重ねて描くためのビュー。タッチは受け取らない。
/// 押した直後は周りの文字を十字に、方向を選ぶとその方向だけを吹き出し（iOS標準のフリックと同じ形）で出す。
final class GuideOverlayView: UIView {
    var guides: [FlickGuide] = [] {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        for g in guides {
            if g.cells != nil { drawCells(g) } else { draw(g, in: ctx) }
        }
    }

    /// かなキーを数字に書き換えて見せる。指のあるキーを濃くする
    private func drawCells(_ g: FlickGuide) {
        guard let cells = g.cells, let ctx = UIGraphicsGetCurrentContext() else { return }
        for c in cells {
            let fill: UIColor = c.selected ? Palette.pressed : Palette.key
            fill.setFill()
            c.path.fill()
            if c.isSector { fill.setStroke(); c.path.stroke() }
            ctx.saveGState()
            ctx.translateBy(x: c.center.x, y: c.center.y)
            ctx.rotate(by: c.rotation)
            drawLabel(c.text, in: CGRect(x: -40, y: -40, width: 80, height: 80), size: c.fontSize,
                      color: c.selected ? Palette.pressedText : Palette.text)
            ctx.restoreGState()
        }
    }

    private static let baseCells: [(FlickDirection, CGFloat, CGFloat)] =
        [(.tap, 0, 0), (.left, -1, 0), (.up, 0, -1), (.right, 1, 0), (.down, 0, 1)]

    private func draw(_ g: FlickGuide, in ctx: CGContext) {
        let w = g.size.width, h = g.size.height
        var cells = Self.baseCells
        if let o = g.offsets {
            cells = cells.map { ($0.0, o[$0.0.rawValue].x, o[$0.0.rawValue].y) }
        }

        var gx: CGFloat = g.center.x
        var gy: CGFloat = g.center.y
        if !g.fixedPosition {
            // 十字全体（幅3キー×高さ3キー）がビューの中に収まるよう、中心をずらす
            let c: CGFloat = abs(cos(g.rotation))
            let s: CGFloat = abs(sin(g.rotation))
            let halfW: CGFloat = (1.5 * w) * c + (1.5 * h) * s
            let halfH: CGFloat = (1.5 * w) * s + (1.5 * h) * c
            let inset: CGFloat = 2
            let minX: CGFloat = halfW + inset
            let maxX: CGFloat = bounds.width - halfW - inset
            let minY: CGFloat = halfH + inset
            let maxY: CGFloat = bounds.height - halfH - inset
            if g.rotation == 0 {
                // 傾いていないキー（端のキーなど）は、十字全体をずらさず、はみ出す方向の候補だけを内側へ寄せる
                // （全体をずらすと、指の位置と候補がずれて見える）
                let lo: CGFloat = (w / 2 + inset - gx) / w
                let hi: CGFloat = (bounds.width - w / 2 - inset - gx) / w
                if lo <= hi { cells = cells.map { ($0.0, min(max($0.1, lo), hi), $0.2) } }
            } else if minX <= maxX {
                gx = min(max(gx, minX), maxX)
            }
            if minY <= maxY { gy = min(max(gy, minY), maxY) }
        }

        ctx.saveGState()
        ctx.translateBy(x: gx, y: gy)
        ctx.rotate(by: g.rotation)
        if g.selected != .tap && !g.keepCross,
           let cell = cells.first(where: { $0.0 == g.selected }), !g.chars[g.selected.rawValue].isEmpty {
            drawBalloon(g.chars[g.selected.rawValue], dx: cell.1, dy: cell.2, w: w, h: h, in: ctx)
        } else {
            drawCross(g, cells: cells, w: w, h: h)
        }
        ctx.restoreGState()
    }

    /// 押した直後：周りの文字を、少し小さめの淡い色のキーで十字に並べる（押したキー自体は下のキーボードに描かれている）
    private func drawCross(_ g: FlickGuide, cells: [(FlickDirection, CGFloat, CGFloat)], w: CGFloat, h: CGFloat) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        var items: [(String, CGRect, Bool)] = []
        for (d, ox, oy) in cells {
            let ch = g.chars[d.rawValue]
            if ch.isEmpty { continue }
            // 文字キーでは、真ん中は押したキーそのものなので描かない（数字の枠は描く）
            if d == .tap && !g.keepCross { continue }
            let r = CGRect(x: ox * w - w / 2, y: oy * h - h / 2, width: w, height: h).insetBy(dx: 4, dy: 4)
            items.append((ch, r, d == g.selected && g.keepCross))
        }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 4, color: UIColor.black.withAlphaComponent(0.3).cgColor)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        for (_, r, selected) in items {
            (selected ? Palette.pressed : Palette.guideSoft).setFill()
            UIBezierPath(roundedRect: r, cornerRadius: min(r.width, r.height) * 0.22).fill()
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        for (ch, r, selected) in items {
            let color: UIColor = selected ? Palette.pressedText : Palette.guideText
            drawLabel(ch, in: r, size: min(w, h) * (ch.count > 1 ? 0.26 : 0.4), color: color)
        }
    }

    /// 方向を選んだとき：選んだ方向に、押したキーを指す吹き出しを出して、選んだ文字を大きく出す（iOS標準と同じ形）
    private func drawBalloon(_ ch: String, dx: CGFloat, dy: CGFloat, w: CGFloat, h: CGFloat, in ctx: CGContext) {
        // 右向きを基準に作ってから、選んだ方向へ回す
        let along: CGFloat = dx != 0 ? w : h      // 伸びる向きの長さ
        let across: CGFloat = dx != 0 ? h : w     // 幅
        // 先は押したキーの側に向け、外側は四角（iOS標準と同じく、押したキーを指す吹き出し）
        let t: CGFloat = along * 0.35
        let a: CGFloat = along * 0.78
        let b: CGFloat = along * 1.68
        let half: CGFloat = across * 0.5
        let path = UIBezierPath()
        path.move(to: CGPoint(x: t, y: 0))
        path.addLine(to: CGPoint(x: a, y: -half))
        path.addLine(to: CGPoint(x: b, y: -half))
        path.addLine(to: CGPoint(x: b, y: half))
        path.addLine(to: CGPoint(x: a, y: half))
        path.close()
        path.lineJoinStyle = .round
        path.lineWidth = 10   // 角を丸く見せるため、同じ色の太い線で縁取る
        let angle: CGFloat = atan2(dy, dx)

        ctx.saveGState()
        ctx.rotate(by: angle)
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 5, color: UIColor.black.withAlphaComponent(0.35).cgColor)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        Palette.guide.setFill()
        Palette.guide.setStroke()
        path.stroke()
        path.fill()
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        // 文字は回さずに、矢印の太い部分の中央へ置く
        let m: CGFloat = (a + b) / 2
        let center = CGPoint(x: dx * m, y: dy * m)
        let size: CGFloat = across * (ch.count > 1 ? 0.32 : 0.6)
        drawLabel(ch, in: CGRect(x: center.x - across / 2, y: center.y - across / 2, width: across, height: across),
                  size: size, color: Palette.text)
    }

    private func drawLabel(_ ch: String, in r: CGRect, size: CGFloat, color: UIColor) {
        let font = UIFont.systemFont(ofSize: size, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let sz = (ch as NSString).size(withAttributes: attrs)
        (ch as NSString).draw(at: CGPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: attrs)
    }
}
