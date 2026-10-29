import UIKit

struct FlickGuide {
    let center: CGPoint
    let size: CGSize
    let rotation: CGFloat
    let chars: [String]
    let selected: FlickDirection
}

/// フリック中の十字ガイドを、変換候補の帯の上にも重ねて描くためのビュー。タッチは受け取らない。
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

    private func draw(_ g: FlickGuide, in ctx: CGContext) {
        let w = g.size.width, h = g.size.height
        let cells: [(FlickDirection, CGFloat, CGFloat)] = [(.tap, 0, 0), (.left, -1, 0), (.up, 0, -1), (.right, 1, 0), (.down, 0, 1)]
        let font = UIFont.systemFont(ofSize: min(w, h) * 0.46, weight: .semibold)

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
        var gx: CGFloat = g.center.x
        var gy: CGFloat = g.center.y
        if minX <= maxX { gx = min(max(gx, minX), maxX) }
        if minY <= maxY { gy = min(max(gy, minY), maxY) }

        ctx.saveGState()
        ctx.translateBy(x: gx, y: gy)
        ctx.rotate(by: g.rotation)
        for (d, ox, oy) in cells {
            let ch = g.chars[d.rawValue]
            if ch.isEmpty { continue }
            let rx: CGFloat = ox * w - w / 2 + 1
            let ry: CGFloat = oy * h - h / 2 + 1
            let r = CGRect(x: rx, y: ry, width: w - 2, height: h - 2)
            let p = UIBezierPath(roundedRect: r, cornerRadius: KeyboardLayout.cornerRadius * 1.6)
            (d == g.selected ? Palette.pressed : Palette.guide).setFill()
            p.fill()
            Palette.shadow.setStroke()
            p.lineWidth = 0.5
            p.stroke()
            let color: UIColor = d == g.selected ? Palette.pressedText : Palette.text
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let sz = (ch as NSString).size(withAttributes: attrs)
            let tx: CGFloat = r.midX - sz.width / 2
            let ty: CGFloat = r.midY - sz.height / 2
            (ch as NSString).draw(at: CGPoint(x: tx, y: ty), withAttributes: attrs)
        }
        ctx.restoreGState()
    }
}
