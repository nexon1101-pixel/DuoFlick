import UIKit

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
        for g in guides { draw(g, in: ctx) }
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
            if minX <= maxX { gx = min(max(gx, minX), maxX) }
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

    /// 押した直後：周りの文字を、少し小さめのキーで十字に並べる
    private func drawCross(_ g: FlickGuide, cells: [(FlickDirection, CGFloat, CGFloat)], w: CGFloat, h: CGFloat) {
        for (d, ox, oy) in cells {
            let ch = g.chars[d.rawValue]
            if ch.isEmpty { continue }
            let selected = d == g.selected
            let r = CGRect(x: ox * w - w / 2, y: oy * h - h / 2, width: w, height: h).insetBy(dx: 2, dy: 2)
            let p = UIBezierPath(roundedRect: r, cornerRadius: min(r.width, r.height) * 0.22)
            if selected { Palette.pressed.setFill() } else { Palette.guide.setFill() }
            p.fill()
            Palette.shadow.setStroke()
            p.lineWidth = 0.5
            p.stroke()
            let color: UIColor = selected ? Palette.pressedText : Palette.text
            drawLabel(ch, in: r, size: min(w, h) * (ch.count > 1 ? 0.26 : 0.46), color: color)
        }
    }

    /// 方向を選んだとき：押したキーから選んだ方向へ伸びる吹き出しに、選んだ文字を大きく出す
    private func drawBalloon(_ ch: String, dx: CGFloat, dy: CGFloat, w: CGFloat, h: CGFloat, in ctx: CGContext) {
        // 吹き出しの頭（選んだ方向のキーより少し大きい）
        let headW: CGFloat = w * 1.15
        let headH: CGFloat = h * 1.15
        let headCenter = CGPoint(x: dx * w * 1.05, y: dy * h * 1.05)
        let head = CGRect(x: headCenter.x - headW / 2, y: headCenter.y - headH / 2, width: headW, height: headH)
        // 押したキーの縁から頭へつなぐ首。キー側を細く、頭側を太くする
        let neck = UIBezierPath()
        if dx != 0 {
            let x0: CGFloat = dx * w * 0.5
            let x1: CGFloat = dx > 0 ? head.minX + 2 : head.maxX - 2
            neck.move(to: CGPoint(x: x0, y: -h * 0.28))
            neck.addLine(to: CGPoint(x: x1, y: -headH * 0.42))
            neck.addLine(to: CGPoint(x: x1, y: headH * 0.42))
            neck.addLine(to: CGPoint(x: x0, y: h * 0.28))
        } else {
            let y0: CGFloat = dy * h * 0.5
            let y1: CGFloat = dy > 0 ? head.minY + 2 : head.maxY - 2
            neck.move(to: CGPoint(x: -w * 0.28, y: y0))
            neck.addLine(to: CGPoint(x: -headW * 0.42, y: y1))
            neck.addLine(to: CGPoint(x: headW * 0.42, y: y1))
            neck.addLine(to: CGPoint(x: w * 0.28, y: y0))
        }
        neck.close()
        let headPath = UIBezierPath(roundedRect: head, cornerRadius: min(headW, headH) * 0.24)

        // 影を付けて、キーの上に浮いているように見せる
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 4, color: UIColor.black.withAlphaComponent(0.35).cgColor)
        Palette.guide.setFill()
        headPath.fill()
        neck.fill()
        ctx.restoreGState()
        Palette.guide.setFill()
        headPath.fill()
        neck.fill()

        drawLabel(ch, in: head, size: min(headW, headH) * (ch.count > 1 ? 0.3 : 0.56), color: Palette.text)
    }

    private func drawLabel(_ ch: String, in r: CGRect, size: CGFloat, color: UIColor) {
        let font = UIFont.systemFont(ofSize: size, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let sz = (ch as NSString).size(withAttributes: attrs)
        (ch as NSString).draw(at: CGPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: attrs)
    }
}
