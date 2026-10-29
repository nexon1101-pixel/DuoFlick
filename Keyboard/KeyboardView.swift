import UIKit

enum Palette {
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
    }
    static let background = dynamic(0xD1D4DA, 0x2B2C30)
    static let key = dynamic(0xFFFFFF, 0x6B6C70)
    static let functionKey = dynamic(0xABB0BA, 0x46474B)
    static let pressed = dynamic(0x2A52C4, 0x8FA7FF)
    static let text = dynamic(0x111318, 0xFFFFFF)
    static let pressedText = dynamic(0xFFFFFF, 0x0C1122)
    static let shadow = dynamic(0x898A8D, 0x111214)
    static let guide = dynamic(0xFFFFFF, 0x3A3B40)
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

/// キーの描画とタッチ判定をまとめて行うビュー。扇形のくさび形キーも描けるよう、自前で描画する。
final class KeyboardView: UIView {
    var settings = KeyboardSettings() {
        didSet { relayout() }
    }
    var onKey: ((KeyDef, FlickDirection) -> Void)?
    /// 上に空けておく高さ（変換候補の帯の分）
    var topInset: CGFloat = 0 {
        didSet { if topInset != oldValue { relayout() } }
    }
    weak var guideView: GuideOverlayView?
    /// 空白キー長押し中の左右移動。負の値で左へ。
    var onCursor: ((Int) -> Void)?

    private(set) var keys: [LaidKey] = []
    private var keysBottom: CGFloat = 0
    private var layoutWidth: CGFloat = 0

    private final class Active {
        let key: LaidKey
        let start: CGPoint
        var current: CGPoint
        var timer: Timer?
        var repeated = false
        var cursorMode = false
        var cursorAnchorX: CGFloat = 0
        init(key: LaidKey, start: CGPoint) {
            self.key = key
            self.start = start
            self.current = start
        }
    }
    private var active: [UITouch: Active] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func requiredHeight(for width: CGFloat) -> CGFloat {
        KeyboardLayout.make(settings: settings, width: width, topInset: topInset).height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width != layoutWidth { relayout() }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        setNeedsDisplay()
    }

    private func relayout() {
        layoutWidth = bounds.width
        guard layoutWidth > 0 else { return }
        let result = KeyboardLayout.make(settings: settings, width: layoutWidth, topInset: topInset)
        keys = result.keys
        keysBottom = result.keysBottom
        setNeedsDisplay()
    }

    // MARK: - 描画

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let pressedIDs = Set(active.values.map { $0.key.def.id })
        let cursorMode = active.values.contains { $0.cursorMode }

        for k in keys {
            let isPressed = pressedIDs.contains(k.def.id)
            let fill: UIColor = isPressed ? Palette.pressed : (k.def.isKana ? Palette.key : Palette.functionKey)

            if let shadow = k.path.copy() as? UIBezierPath {
                shadow.apply(CGAffineTransform(translationX: 0, y: 1))
                Palette.shadow.setFill()
                shadow.fill()
                if k.isSector { Palette.shadow.setStroke(); shadow.stroke() }
            }
            fill.setFill()
            k.path.fill()
            if k.isSector { fill.setStroke(); k.path.stroke() }

            let m = min(k.size.width, k.size.height)
            let single = k.def.isKana && k.def.label.count == 1
            let ratio: CGFloat = single ? 0.44 : 0.28
            let font = UIFont.systemFont(ofSize: m * ratio, weight: .regular)
            var label = k.def.label
            if cursorMode, case .space = k.def.action { label = "◀ ▶" }
            drawText(label, center: k.center, rotation: textRotation(k), font: font,
                     color: isPressed ? Palette.pressedText : Palette.text, in: ctx)
        }

        updateGuides()
    }

    private func updateGuides() {
        var list: [FlickGuide] = []
        for a in active.values {
            if case .kana(let chars) = a.key.def.action {
                list.append(FlickGuide(center: a.key.center, size: a.key.size, rotation: textRotation(a.key),
                                       chars: chars, selected: direction(a.key, from: a.start, to: a.current)))
            }
        }
        guideView?.guides = list
    }

    private func drawText(_ s: String, center: CGPoint, rotation: CGFloat, font: UIFont, color: UIColor, in ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (s as NSString).size(withAttributes: attrs)
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: rotation)
        (s as NSString).draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2), withAttributes: attrs)
        ctx.restoreGState()
    }

    private func textRotation(_ k: LaidKey) -> CGFloat {
        settings.followFan ? k.rotation : 0
    }

    // MARK: - 判定

    /// 最下段より下は反応させない。キーの隙間は一番近いキーとして扱う。
    private func hit(_ p: CGPoint) -> LaidKey? {
        if p.y > keysBottom || p.y < topInset { return nil }
        var best: LaidKey?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for k in keys {
            if k.path.contains(p) { return k }
            let dx: CGFloat = p.x - k.center.x
            let dy: CGFloat = p.y - k.center.y
            let c: CGFloat = cos(k.rotation)
            let s: CGFloat = sin(k.rotation)
            let lx: CGFloat = dx * c + dy * s
            let ly: CGFloat = dy * c - dx * s
            let ox: CGFloat = max(0, abs(lx) - k.size.width / 2)
            let oy: CGFloat = max(0, abs(ly) - k.size.height / 2)
            let d: CGFloat = hypot(ox, oy)
            if d < bestDistance { bestDistance = d; best = k }
        }
        let limit: CGFloat = 8 * CGFloat(KeyboardSettings.ptPerMM)
        return bestDistance <= limit ? best : nil
    }

    private func direction(_ k: LaidKey, from s: CGPoint, to e: CGPoint) -> FlickDirection {
        guard k.def.isKana else { return .tap }
        let dx: CGFloat = e.x - s.x
        let dy: CGFloat = e.y - s.y
        let lengthMM: CGFloat = hypot(dx, dy) / CGFloat(KeyboardSettings.ptPerMM)
        if lengthMM < CGFloat(settings.flickMinMM) { return .tap }
        // キーの傾きと、設定した傾き補正を差し引いた角度（右=0、上=90）
        let toDeg: CGFloat = 180 / CGFloat.pi
        let raw: CGFloat = atan2(-dy, dx) * toDeg
        let keyTilt: CGFloat = textRotation(k) * toDeg
        var a: CGFloat = raw + keyTilt - CGFloat(settings.tiltDeg)
        a = a.truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        if a < 45 || a >= 315 { return .right }
        if a < 135 { return .up }
        if a < 225 { return .left }
        return .down
    }

    // MARK: - タッチ

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let p = t.location(in: self)
            guard let k = hit(p) else { continue }
            let a = Active(key: k, start: p)
            if case .delete = k.def.action {
                a.timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self, weak a] _ in
                    guard let self, let a else { return }
                    a.repeated = true
                    self.onKey?(k.def, .tap)
                    a.timer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in
                        self?.onKey?(k.def, .tap)
                    }
                }
            }
            if case .space = k.def.action {
                a.timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self, weak a] _ in
                    guard let self, let a else { return }
                    a.cursorMode = true
                    a.cursorAnchorX = a.current.x
                    self.setNeedsDisplay()
                }
            }
            active[t] = a
        }
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let stepPt: CGFloat = 2.2 * CGFloat(KeyboardSettings.ptPerMM)
        for t in touches {
            guard let a = active[t] else { continue }
            let p = t.location(in: self)
            a.current = p
            if case .space = a.key.def.action, !a.cursorMode {
                // 長押しを待たずに横へ大きく動かしたときも、カーソル移動にする
                if abs(p.x - a.start.x) > stepPt * 1.5 {
                    a.timer?.invalidate()
                    a.cursorMode = true
                    a.cursorAnchorX = a.start.x
                }
            }
            if a.cursorMode {
                let moved: CGFloat = p.x - a.cursorAnchorX
                let steps = Int(moved / stepPt)
                if steps != 0 {
                    onCursor?(steps)
                    a.cursorAnchorX += CGFloat(steps) * stepPt
                }
            }
        }
        setNeedsDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard let a = active.removeValue(forKey: t) else { continue }
            a.timer?.invalidate()
            if !a.repeated && !a.cursorMode {
                onKey?(a.key.def, direction(a.key, from: a.start, to: t.location(in: self)))
            }
        }
        setNeedsDisplay()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            active.removeValue(forKey: t)?.timer?.invalidate()
        }
        setNeedsDisplay()
    }
}
