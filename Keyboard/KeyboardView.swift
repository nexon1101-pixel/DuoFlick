import UIKit

/// 配色。ライト・ダークでそれぞれ選べる
struct KeyTheme {
    let id: String
    let name: String
    let lightKey: UInt32, lightFn: UInt32
    let darkKey: UInt32, darkFn: UInt32

    static let all: [KeyTheme] = [
        KeyTheme(id: "standard", name: "標準", lightKey: 0xFFFFFF, lightFn: 0xABB0BA, darkKey: 0x6B6C70, darkFn: 0x46474B),
        KeyTheme(id: "blue", name: "青", lightKey: 0xE8F0FF, lightFn: 0xA9BEE8, darkKey: 0x3D5A8C, darkFn: 0x2A3B5C),
        KeyTheme(id: "green", name: "緑", lightKey: 0xE9F7EE, lightFn: 0xA8CDB5, darkKey: 0x3E6B52, darkFn: 0x2B4637),
        KeyTheme(id: "pink", name: "桃", lightKey: 0xFFEEF3, lightFn: 0xE6B3C4, darkKey: 0x7A4A5C, darkFn: 0x523240),
        KeyTheme(id: "mono", name: "モノクロ", lightKey: 0xF2F2F2, lightFn: 0xC8C8C8, darkKey: 0x3A3A3A, darkFn: 0x262626),
    ]

    static func find(_ id: String) -> KeyTheme { all.first { $0.id == id } ?? all[0] }
}

enum Palette {
    /// 今の設定の配色（ライト用・ダーク用）
    static var lightTheme = KeyTheme.all[0]
    static var darkTheme = KeyTheme.all[0]

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
    }
    static let background = dynamic(0xD1D4DA, 0x2B2C30)
    static let key = UIColor { t in
        UIColor(hex: t.userInterfaceStyle == .dark ? darkTheme.darkKey : lightTheme.lightKey)
    }
    static let functionKey = UIColor { t in
        UIColor(hex: t.userInterfaceStyle == .dark ? darkTheme.darkFn : lightTheme.lightFn)
    }
    static let pressed = dynamic(0x2A52C4, 0x8FA7FF)
    static let text = dynamic(0x111318, 0xFFFFFF)
    static let pressedText = dynamic(0xFFFFFF, 0x0C1122)
    /// 確定・検索などのキー（iOS標準と同じ青）
    static let accent = dynamic(0x007AFF, 0x0A84FF)
    static let shadow = dynamic(0x898A8D, 0x111214)
    static let guide = dynamic(0xFFFFFF, 0x77787D)
    /// 押した直後に周りへ出す文字の下地と文字色（キーより淡くして区別する）
    static let guideSoft = dynamic(0xF4F5F7, 0x5A5B60)
    static let guideText = dynamic(0x555A63, 0xD8D9DD)
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
    /// 状態で変わるキーの表示（改行→確定、空白→次候補など）
    var labelOverrides: [String: String] = [:] {
        didSet { if labelOverrides != oldValue { setNeedsDisplay() } }
    }
    /// 青く目立たせるキー（確定・検索など）
    var accentIDs: Set<String> = [] {
        didSet { if accentIDs != oldValue { setNeedsDisplay() } }
    }
    /// 押せないキー（文字が空のときの送信など）
    var disabledIDs: Set<String> = [] {
        didSet { if disabledIDs != oldValue { setNeedsDisplay() } }
    }
    var settings = KeyboardSettings() {
        didSet {
            Palette.lightTheme = KeyTheme.find(settings.themeLight)
            Palette.darkTheme = KeyTheme.find(settings.themeDark)
            relayout()
        }
    }
    var onKey: ((KeyDef, FlickDirection) -> Void)?
    /// キーを押した瞬間（キー音用）
    var onPress: (() -> Void)?
    var mode: InputMode = .kana {
        didSet { if mode != oldValue { relayout() } }
    }
    var grip: Grip = .one {
        didSet { if grip != oldValue { relayout() } }
    }
    /// 英字を大文字で表示する（⇧）
    var uppercase = false {
        didSet { if uppercase != oldValue { setNeedsDisplay() } }
    }
    /// ⇧を固定中
    var capsLock = false {
        didSet { if capsLock != oldValue { setNeedsDisplay() } }
    }
    /// 上に空けておく高さ（変換候補の帯の分）
    var topInset: CGFloat = 0 {
        didSet { if topInset != oldValue { relayout() } }
    }
    weak var guideView: GuideOverlayView?
    /// 空白キー長押し中の左右移動。負の値で左へ。
    var onCursor: ((Int) -> Void)?
    /// 空白キー長押し中の上下移動。負の値で上へ。
    var onCursorVertical: ((Int) -> Void)?

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
        var cursorAnchorY: CGFloat = 0
        /// 数字キー：0なら0〜4、1なら5〜9の枠を開いた
        var numberStage: Int?
        var numberAnchor: CGPoint = .zero
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
        KeyboardLayout.make(settings: settings, mode: mode, grip: grip, width: width, topInset: topInset).height
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
        let result = KeyboardLayout.make(settings: settings, mode: mode, grip: grip, width: layoutWidth, topInset: topInset)
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
            let accent = accentIDs.contains(k.def.id) && !disabledIDs.contains(k.def.id)
            let fill: UIColor = isPressed ? Palette.pressed
                : (accent ? Palette.accent : (k.def.isCharacter ? Palette.key : Palette.functionKey))

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
            let single = (k.def.isCharacter && k.def.label.count == 1) || k.def.id == "number"
            let ratio: CGFloat = single ? 0.44 : 0.28
            let font = UIFont.systemFont(ofSize: m * ratio * CGFloat(settings.labelScale), weight: .regular)
            var label = labelOverrides[k.def.id] ?? k.def.label
            if uppercase, mode == .qwerty, k.def.id.hasPrefix("q_") { label = label.uppercased() }
            if case .shift = k.def.action { label = capsLock ? "⇪" : (uppercase ? "⬆︎" : "⇧") }
            if cursorMode, case .space = k.def.action { label = "◀ ▲▼ ▶" }
            var color = isPressed ? Palette.pressedText : (accent ? UIColor.white : Palette.text)
            if disabledIDs.contains(k.def.id) { color = color.withAlphaComponent(0.35) }
            var symbolName = k.def.symbol
            // シフトは状態で記号を変える（iOS標準と同じ：通常・大文字・固定）
            if case .shift = k.def.action { symbolName = capsLock ? "capslock.fill" : (uppercase ? "shift.fill" : "shift") }
            if let symbol = symbolName {
                drawSymbol(symbol, center: k.center, rotation: textRotation(k),
                           pointSize: m * 0.36 * CGFloat(settings.labelScale), color: color, in: ctx)
            } else {
                drawText(label, center: k.center, rotation: textRotation(k), font: font, color: color, in: ctx)
            }
        }

        updateGuides()
    }

    private func updateGuides() {
        var list: [FlickGuide] = []
        for a in active.values {
            if a.key.def.isNumberPad {
                // 動かす前は、何も出さない（動かすと数字の配置が出る）
                if a.numberStage != nil { list.append(numberGuide(a)) }
            } else if let chars = guideChars(a.key.def) {
                list.append(FlickGuide(center: a.key.center, size: a.key.size, rotation: textRotation(a.key),
                                       chars: chars, selected: direction(a.key, from: a.start, to: a.current)))
            }
        }
        guideView?.guides = list
    }

    /// フリックのガイドに出す文字。1方向しかないキー（英字など）は出さない
    private func guideChars(_ def: KeyDef) -> [String]? {
        if case .nextKeyboard = def.action { return ["", "定型文", "設定", "履歴", ""] }
        guard let chars = def.flickChars, chars.filter({ !$0.isEmpty }).count > 1 else { return nil }
        return chars
    }

    /// 数字を入れるときに書き換えるかなキー（電話の配置：あかさ＝123、たなは＝456、まやら＝789、わ＝0）
    private static let numberKeyDigits = ["a": "1", "ka": "2", "sa": "3", "ta": "4", "na": "5",
                                          "ha": "6", "ma": "7", "ya": "8", "ra": "9", "wa": "0"]

    /// 指のある、数字に書き換えたキー
    private func numberKey(at p: CGPoint) -> LaidKey? {
        keys.first { Self.numberKeyDigits[$0.def.id] != nil && $0.path.contains(p) }
    }

    private func numberGuide(_ a: Active) -> FlickGuide {
        let current = numberKey(at: a.current)?.def.id
        let cells: [GuideCell] = keys.compactMap { k in
            guard let d = Self.numberKeyDigits[k.def.id] else { return nil }
            let m: CGFloat = min(k.size.width, k.size.height)
            return GuideCell(path: k.path, center: k.center, rotation: textRotation(k), text: d,
                             selected: k.def.id == current,
                             fontSize: m * 0.5 * CGFloat(settings.labelScale), isSector: k.isSector)
        }
        return FlickGuide(center: .zero, size: .zero, rotation: 0, chars: [], selected: .tap, cells: cells)
    }

    /// 数字キーを押したまま少し動かしたら、かなキーを数字に書き換えて見せる。離したときに、指のあるキーの数字を入れる
    private func trackNumber(_ a: Active, _ p: CGPoint) {
        guard a.numberStage == nil else { return }
        let dx: CGFloat = p.x - a.start.x
        let dy: CGFloat = p.y - a.start.y
        let need: CGFloat = max(CGFloat(settings.flickMinMM) * CGFloat(KeyboardSettings.ptPerMM),
                                min(a.key.size.width, a.key.size.height) * 0.5)
        guard hypot(dx, dy) >= need else { return }
        a.numberStage = 0
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

    /// iOS標準と同じ、単色の記号（地球儀など）を描く
    private func drawSymbol(_ name: String, center: CGPoint, rotation: CGFloat, pointSize: CGFloat, color: UIColor, in ctx: CGContext) {
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let image = UIImage(systemName: name, withConfiguration: config)?
            .withTintColor(color, renderingMode: .alwaysOriginal) else { return }
        let size = image.size
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: rotation)
        image.draw(in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        ctx.restoreGState()
    }

    private func textRotation(_ k: LaidKey) -> CGFloat {
        settings.followFan ? k.rotation : 0
    }

    // MARK: - ずれの自動補正

    private static let offsetKey = "DuoFlick.touchOffset.v1"
    private(set) var touchOffset: CGPoint = {
        let a = UserDefaults.standard.array(forKey: KeyboardView.offsetKey) as? [Double] ?? [0, 0]
        return a.count == 2 ? CGPoint(x: a[0], y: a[1]) : .zero
    }()

    /// 文字キーをタップした位置と、そのキーの中心とのずれを少しずつ平均する
    private func learnOffset(_ p: CGPoint, _ k: LaidKey) {
        guard settings.autoCorrect else { return }
        let rate: CGFloat = 0.03
        let limit: CGFloat = 3 * CGFloat(KeyboardSettings.ptPerMM)
        let dx: CGFloat = p.x - k.center.x
        let dy: CGFloat = p.y - k.center.y
        var x: CGFloat = touchOffset.x + (dx - touchOffset.x) * rate
        var y: CGFloat = touchOffset.y + (dy - touchOffset.y) * rate
        x = min(max(x, -limit), limit)
        y = min(max(y, -limit), limit)
        touchOffset = CGPoint(x: x, y: y)
        UserDefaults.standard.set([Double(x), Double(y)], forKey: Self.offsetKey)
    }

    func resetOffset() {
        touchOffset = .zero
        UserDefaults.standard.removeObject(forKey: Self.offsetKey)
        flickBounds = [0, 0, 0, 0]
        UserDefaults.standard.removeObject(forKey: Self.boundsKey)
    }

    /// 調整バーに出す、今の補正量（mm）
    var offsetDescription: String {
        let mx = Double(touchOffset.x) / KeyboardSettings.ptPerMM
        let my = Double(touchOffset.y) / KeyboardSettings.ptPerMM
        let moved = flickBounds.filter { abs($0) >= 1 }.count
        let angle = moved == 0 ? "" : "・方向 \(moved)か所"
        return String(format: "横 %+.1fmm・縦 %+.1fmm", mx, my) + angle
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

    /// フリックの角度（右=0、上=90、0〜360）。キーの傾きと設定した傾き補正を差し引く。フリックに満たなければ nil
    private func flickAngle(_ k: LaidKey, from s: CGPoint, to e: CGPoint) -> CGFloat? {
        let dx: CGFloat = e.x - s.x
        let dy: CGFloat = e.y - s.y
        let lengthMM: CGFloat = hypot(dx, dy) / CGFloat(KeyboardSettings.ptPerMM)
        if lengthMM < CGFloat(settings.flickMinMM) { return nil }
        let toDeg: CGFloat = 180 / CGFloat.pi
        let raw: CGFloat = atan2(-dy, dx) * toDeg
        let keyTilt: CGFloat = textRotation(k) * toDeg
        var a: CGFloat = raw + keyTilt - CGFloat(settings.tiltDeg)
        a = a.truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        return a
    }

    private func direction(_ k: LaidKey, from s: CGPoint, to e: CGPoint) -> FlickDirection {
        guard k.def.isCharacter || k.def.isDelete || k.def.isSettings else { return .tap }
        guard let a = flickAngle(k, from: s, to: e) else { return .tap }
        // 文字キーは、覚えたくせの分だけ方向の境目をずらす
        let b: [CGFloat] = k.def.isCharacter && settings.autoCorrect ? flickBounds : [0, 0, 0, 0]
        let edges: [CGFloat] = (0..<4).map { 45 + 90 * CGFloat($0) + b[$0] }
        if a >= edges[0] && a < edges[1] { return .up }
        if a >= edges[1] && a < edges[2] { return .left }
        if a >= edges[2] && a < edges[3] { return .down }
        return .right
    }

    // MARK: - 斜めのくせの補正

    private static let boundsKey = "DuoFlick.flickBounds.v1"
    /// 上下左右の境目（右上・左上・左下・右下）を、標準の45°からどれだけずらすか（度）
    private(set) var flickBounds: [CGFloat] = {
        let a = UserDefaults.standard.array(forKey: KeyboardView.boundsKey) as? [Double] ?? []
        return a.count == 4 ? a.map { CGFloat($0) } : [0, 0, 0, 0]
    }()

    /// 直前の文字キーのフリックと、そのあと⌫で消したかどうか
    private struct LastFlick {
        let keyID: String
        let dir: FlickDirection
        let angle: CGFloat
        let time: Date
        var deleted = false
    }
    private var lastFlick: LastFlick?

    /// 文字キーを離したときに呼ぶ。フリック→⌫→同じキーを隣の方向へフリック、の流れを判定ミスとみなして境目をずらす
    private func noteFlick(_ k: LaidKey, dir: FlickDirection, from s: CGPoint, to e: CGPoint) {
        let now = Date()
        defer {
            if dir != .tap, let angle = flickAngle(k, from: s, to: e) {
                lastFlick = LastFlick(keyID: k.def.id, dir: dir, angle: angle, time: now)
            } else {
                lastFlick = nil
            }
        }
        guard settings.autoCorrect, let last = lastFlick, last.deleted, last.keyID == k.def.id,
              dir != .tap, dir != last.dir, now.timeIntervalSince(last.time) < 4,
              let index = boundary(last.dir, dir) else { return }
        learnBoundary(index, angle: last.angle, towards: dir)
    }

    /// ⌫で1文字消したときに呼ぶ
    private func noteDelete() {
        guard var last = lastFlick, !last.deleted else { lastFlick = nil; return }
        last.deleted = true
        lastFlick = last
    }

    /// 隣り合う2つの方向の間の境目の番号（0:右と上、1:上と左、2:左と下、3:下と右）
    private func boundary(_ a: FlickDirection, _ b: FlickDirection) -> Int? {
        let pair = Set([a, b])
        if pair == [.right, .up] { return 0 }
        if pair == [.up, .left] { return 1 }
        if pair == [.left, .down] { return 2 }
        if pair == [.down, .right] { return 3 }
        return nil   // 反対向き（上と下など）は判定ミスではないので扱わない
    }

    private func learnBoundary(_ i: Int, angle: CGFloat, towards dir: FlickDirection) {
        let edge: CGFloat = 45 + 90 * CGFloat(i) + flickBounds[i]
        var a: CGFloat = angle
        if i == 3 && a < 180 { a += 360 }   // 右下の境目は 315° をまたぐので、0°付近を 360° 以降として扱う
        guard abs(a - edge) < 40 else { return }
        // 境目より角度の大きい側の方向（0:上、1:左、2:下、3:右）
        let upper: FlickDirection = [.up, .left, .down, .right][i]
        // 今回の角度が、打ち直した方向の側に入るように境目を動かす（少しずつ、最大±20°）
        let target: CGFloat = dir == upper ? a - 4 : a + 4
        var b: CGFloat = flickBounds[i] + (target - edge) * 0.35
        b = min(max(b, -20), 20)
        flickBounds[i] = b
        UserDefaults.standard.set(flickBounds.map { Double($0) }, forKey: Self.boundsKey)
    }


    // MARK: - タッチ

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let p = t.location(in: self)
            // ずれの自動補正：いつもずれる方向の分だけ、押した位置を戻してから判定する
            let q = settings.autoCorrect ? CGPoint(x: p.x - touchOffset.x, y: p.y - touchOffset.y) : p
            guard let k = hit(q) else { continue }
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
                    a.cursorAnchorY = a.current.y
                    self.setNeedsDisplay()
                }
            }
            active[t] = a
            onPress?()
        }
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let stepPt: CGFloat = 2.2 * CGFloat(KeyboardSettings.ptPerMM)
        for t in touches {
            guard let a = active[t] else { continue }
            let p = t.location(in: self)
            a.current = p
            if a.key.def.isNumberPad { trackNumber(a, p) }
            if case .space = a.key.def.action, !a.cursorMode {
                // 長押しを待たずに横へ大きく動かしたときも、カーソル移動にする
                if abs(p.x - a.start.x) > stepPt * 1.5 {
                    a.timer?.invalidate()
                    a.cursorMode = true
                    a.cursorAnchorX = a.start.x
                    a.cursorAnchorY = a.start.y
                }
            }
            if a.key.def.isDelete, !a.repeated {
                // ⌫をフリックし始めたら長押しの連続削除はやめる
                let movedMM: CGFloat = hypot(p.x - a.start.x, p.y - a.start.y) / CGFloat(KeyboardSettings.ptPerMM)
                if movedMM >= CGFloat(settings.flickMinMM) { a.timer?.invalidate() }
            }
            if a.cursorMode {
                let moved: CGFloat = p.x - a.cursorAnchorX
                let steps = Int(moved / stepPt)
                if steps != 0 {
                    onCursor?(steps)
                    a.cursorAnchorX += CGFloat(steps) * stepPt
                }
                let lineStep: CGFloat = 4.5 * CGFloat(KeyboardSettings.ptPerMM)
                let movedY: CGFloat = p.y - a.cursorAnchorY
                let lines = Int(movedY / lineStep)
                if lines != 0 {
                    onCursorVertical?(lines)
                    a.cursorAnchorY += CGFloat(lines) * lineStep
                }
            }
        }
        setNeedsDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard let a = active.removeValue(forKey: t) else { continue }
            a.timer?.invalidate()
            if a.key.def.isNumberPad {
                // タップだけでは何も入れない
                if a.numberStage != nil, let k = numberKey(at: t.location(in: self)),
                   let digit = Self.numberKeyDigits[k.def.id] {
                    onKey?(KeyDef(id: "digit" + digit, label: digit, action: .direct([digit, "", "", "", ""])), .tap)
                }
                continue
            }
            if !a.repeated && !a.cursorMode {
                let end = t.location(in: self)
                let dir = direction(a.key, from: a.start, to: end)
                if dir == .tap, a.key.def.isCharacter { learnOffset(a.start, a.key) }
                if a.key.def.isCharacter {
                    noteFlick(a.key, dir: dir, from: a.start, to: end)
                } else if a.key.def.isDelete && dir == .tap {
                    noteDelete()
                } else {
                    lastFlick = nil
                }
                onKey?(a.key.def, dir)
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
