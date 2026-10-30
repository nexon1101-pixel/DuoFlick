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
    /// フリックで選んでいる方向が変わったとき（振動用）
    var onFlickChange: (() -> Void)?
    var mode: InputMode = .kana {
        didSet { if mode != oldValue { numberLocked = false; relayout() } }
    }
    /// 数字の固定中（123を2回続けてタップで入る。もう1回タップで解除）。かなキーが数字のままになる
    private(set) var numberLocked = false {
        didSet { if numberLocked != oldValue { setNeedsDisplay(); updateGuides() } }
    }
    private var lastNumberTap = Date.distantPast
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
    /// 実際に空ける高さ。iOS標準の配置のときは、候補の帯を出さないので空けない
    private func inset(for width: CGFloat) -> CGFloat {
        KeyboardLayout.usesIOS(settings, mode, grip, width) ? 0 : topInset
    }
    weak var guideView: GuideOverlayView?
    /// 空白キー長押し中の左右移動。負の値で左へ。
    var onCursor: ((Int) -> Void)?
    /// 空白キー長押し中の上下移動。負の値で上へ。
    var onCursorVertical: ((Int) -> Void)?

    private(set) var keys: [LaidKey] = []
    private var keysBottom: CGFloat = 0
    private var layoutWidth: CGFloat = 0

    /// 改行・確定キーの上でこの秒数だけ止めると、キャンセルになる
    private static let cancelHold: TimeInterval = 0.35

    private final class Active {
        let key: LaidKey
        let start: CGPoint
        var current: CGPoint
        var timer: Timer?
        var repeated = false
        var cursorMode = false
        /// 改行・確定キーの上に指が来た時刻（少し止めたときだけキャンセルにする）
        var cancelSince: Date?
        var cancelTimer: Timer?
        var cursorAnchorX: CGFloat = 0
        var cursorAnchorY: CGFloat = 0
        /// 数字キー：0なら0〜4、1なら5〜9の枠を開いた
        var numberStage: Int?
        var numberAnchor: CGPoint = .zero
        var lastDir: FlickDirection = .tap
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
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.cancelsTouchesInView = true
        addGestureRecognizer(pinch)
    }

    /// 両手持ちで、ピンチアウトしたらかなを左右に分け、ピンチインしたら元に戻す
    var onPinch: ((Bool) -> Void)?
    /// 真ん中の候補の一覧を出す範囲（iOS標準の配置のときだけ）
    private(set) var panelRect: CGRect?
    var onPanelRect: ((CGRect?) -> Void)?
    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        guard g.state == .ended || g.state == .changed, mode == .kana else { return }
        if g.scale > 1.25 { g.state = .ended; onPinch?(true) }
        else if g.scale < 0.8 { g.state = .ended; onPinch?(false) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func requiredHeight(for width: CGFloat) -> CGFloat {
        KeyboardLayout.make(settings: settings, mode: mode, grip: grip, width: width, topInset: inset(for: width)).height
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
        let result = KeyboardLayout.make(settings: settings, mode: mode, grip: grip, width: layoutWidth, topInset: inset(for: layoutWidth))
        keys = result.keys
        panelRect = result.panelRect
        onPanelRect?(result.panelRect)
        keysBottom = result.keysBottom
        setNeedsDisplay()
    }

    // MARK: - 描画

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let pressedCenters = active.values.map { $0.key.center }
        let cursorMode = active.values.contains { $0.cursorMode }
        // フリック中（空白のカーソル移動以外）は、改行・確定キーを「取消」にする（そこで離すと何も入らない）
        let cancelHint = active.values.contains { a in
            if a.cursorMode || a.repeated || a.key.def.isNumberPad { return false }
            if case .newline = a.key.def.action { return false }
            guard let since = a.cancelSince else { return false }
            return Date().timeIntervalSince(since) >= Self.cancelHold
        }

        for k in keys {
            let isPressed = pressedCenters.contains(k.center)
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
            let lockedDigit: String? = numberLocked ? Self.numberKeyDigits[k.def.id] : nil
            let single = (k.def.isCharacter && k.def.label.count == 1) || k.def.id == "number" || lockedDigit != nil
            let ratio: CGFloat = single ? 0.44 : 0.28
            let font = UIFont.systemFont(ofSize: m * ratio * CGFloat(settings.labelScale), weight: .regular)
            var label = labelOverrides[k.def.id] ?? k.def.label
            if let d = lockedDigit { label = d }
            if numberLocked, k.def.isNumberPad { label = "あ" }
            if uppercase, mode == .qwerty, k.def.id.hasPrefix("q_") { label = label.uppercased() }
            if case .shift = k.def.action { label = capsLock ? "⇪" : (uppercase ? "⬆︎" : "⇧") }
            if cursorMode, case .space = k.def.action { label = "◀ ▲▼ ▶" }
            var cancelKey = false
            if cancelHint, case .newline = k.def.action { label = "取消"; cancelKey = true }
            var color = isPressed ? Palette.pressedText : (accent ? UIColor.white : Palette.text)
            if disabledIDs.contains(k.def.id) { color = color.withAlphaComponent(0.35) }
            var symbolName = k.def.symbol
            // シフトは状態で記号を変える（iOS標準と同じ：通常・大文字・固定）
            if case .shift = k.def.action { symbolName = capsLock ? "capslock.fill" : (uppercase ? "shift.fill" : "shift") }
            // 普通の改行のときは、リターンの記号にする（確定・検索などは文字のまま）
            if case .newline = k.def.action, label == "改行" { symbolName = "return" }
            if cancelKey { symbolName = nil }
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
        if numberLocked, Self.numberKeyDigits[def.id] != nil { return nil }
        if case .nextKeyboard = def.action { return ["", "", "設定", "履歴", "定型文"] }
        if case .delete = def.action { return ["", "行削除", "語削除", "", "取り消し"] }
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
        let current = numberKey(at: a.current)?.center
        let cells: [GuideCell] = keys.compactMap { k in
            guard let d = Self.numberKeyDigits[k.def.id] else { return nil }
            let m: CGFloat = min(k.size.width, k.size.height)
            return GuideCell(path: k.path, center: k.center, rotation: textRotation(k), text: d,
                             selected: k.center == current,
                             fontSize: m * 0.5 * CGFloat(settings.labelScale), isSector: k.isSector)
        }
        return FlickGuide(center: .zero, size: .zero, rotation: 0, chars: [], selected: .tap, cells: cells)
    }

    /// 数字キーを押したまま少し動かしたら、かなキーを数字に書き換えて見せる。離したときに、指のあるキーの数字を入れる
    private func trackNumber(_ a: Active, _ p: CGPoint) {
        guard a.numberStage == nil, !numberLocked else { return }
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

    /// キーごとの、全体のずれからの差（親指が届きにくい端や下の段は、ずれ方が違うため）
    private static let keyOffsetsKey = "DuoFlick.keyOffsets.v1"
    private var keyDeltas: [String: CGPoint] = {
        let d = UserDefaults.standard.dictionary(forKey: KeyboardView.keyOffsetsKey) as? [String: [Double]] ?? [:]
        return d.compactMapValues { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
    }()
    private static let deltaLimitMM: CGFloat = 2

    private func saveKeyDeltas() {
        let d = keyDeltas.mapValues { [Double($0.x), Double($0.y)] }
        UserDefaults.standard.set(d, forKey: Self.keyOffsetsKey)
    }

    /// そのキーを押すときの、実際に使うずれ（全体のずれ＋キーごとの差）
    private func effectiveOffset(_ id: String) -> CGPoint {
        let d = keyDeltas[id] ?? .zero
        return CGPoint(x: touchOffset.x + d.x, y: touchOffset.y + d.y)
    }

    private func moveDelta(_ id: String, toward target: CGPoint, rate: CGFloat) {
        let cur = keyDeltas[id] ?? .zero
        let limit: CGFloat = Self.deltaLimitMM * CGFloat(KeyboardSettings.ptPerMM)
        let x = min(max(cur.x + (target.x - cur.x) * rate, -limit), limit)
        let y = min(max(cur.y + (target.y - cur.y) * rate, -limit), limit)
        keyDeltas[id] = CGPoint(x: x, y: y)
    }

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
        // キーごとの差：このキーでは、全体のずれよりどれだけ余計にずれたか
        moveDelta(k.def.id, toward: CGPoint(x: dx - x, y: dy - y), rate: 0.05)
        saveKeyDeltas()
    }

    /// 打ち間違いから学ぶ：Aを押して消し、隣のBを打ち直したとき、最初に触った位置はBを押すつもりだったとみなし、
    /// Bを押すときの触る位置が、Aの側へずれているものとして、Bのずれを動かす
    private func learnKeyMiss(old: FlickRecord, intended b: LaidKey) -> Bool {
        guard let a = keys.first(where: { $0.def.id == old.keyID }), a.def.isCharacter, b.def.isCharacter else { return false }
        let bSize: CGFloat = max(b.size.width, b.size.height)
        guard hypot(a.center.x - b.center.x, a.center.y - b.center.y) < 1.8 * bSize,
              hypot(old.point.x - b.center.x, old.point.y - b.center.y) < 0.85 * bSize else { return false }
        let target = CGPoint(x: old.point.x - b.center.x - touchOffset.x, y: old.point.y - b.center.y - touchOffset.y)
        moveDelta(b.def.id, toward: target, rate: 0.2)
        saveKeyDeltas()
        return true
    }

    func resetOffset() {
        touchOffset = .zero
        keyDeltas = [:]
        UserDefaults.standard.removeObject(forKey: Self.keyOffsetsKey)
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
        if p.y > keysBottom || p.y < inset(for: layoutWidth) { return nil }
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

    /// 打った文字キーの記録（タップは方向なし）
    private struct FlickRecord {
        let keyID: String
        let dir: FlickDirection
        let angle: CGFloat?
        let point: CGPoint   // 触り始めた位置
    }
    /// 最近打った文字キー（新しい順に末尾）。⌫で消すたびに、末尾から取り出す
    private var flickHistory: [FlickRecord] = []
    /// ⌫で消した文字キー（打った順）。打ち直した文字と、前から順に突き合わせる
    private var pendingDeleted: [FlickRecord] = []
    private var lastDeleteTime = Date.distantPast
    private static let retypeWindow: TimeInterval = 6

    /// 変換候補・予測候補を選んだときなど、打った文字と画面の文字が対応しなくなったときに呼ぶ
    func resetFlickHistory() {
        flickHistory.removeAll()
        pendingDeleted.removeAll()
    }

    /// 文字キーを離したときに呼ぶ。数文字打ってから⌫で消して打ち直したとき、同じ位置のキーが
    /// 隣の方向に変わっていたら、判定ミスとみなして境目をずらす
    private func noteFlick(_ k: LaidKey, dir: FlickDirection, from s: CGPoint, to e: CGPoint) {
        let angle: CGFloat? = dir == .tap ? nil : flickAngle(k, from: s, to: e)
        if !pendingDeleted.isEmpty {
            if Date().timeIntervalSince(lastDeleteTime) > Self.retypeWindow {
                pendingDeleted.removeAll()
            } else {
                let old = pendingDeleted.removeFirst()
                if old.keyID != k.def.id {
                    // 隣のキーを押し間違えて打ち直した場合は、そのキーのずれを学習して続ける。それ以外は打ち替えなので、突き合わせはやめる
                    if !(settings.autoCorrect && old.dir == .tap && dir == .tap && learnKeyMiss(old: old, intended: k)) {
                        pendingDeleted.removeAll()
                    }
                } else if settings.autoCorrect, let oldAngle = old.angle, angle != nil,
                          dir != .tap, old.dir != .tap, dir != old.dir,
                          let index = boundary(old.dir, dir) {
                    learnBoundary(index, angle: oldAngle, towards: dir)
                }
            }
        }
        flickHistory.append(FlickRecord(keyID: k.def.id, dir: dir, angle: angle, point: s))
        if flickHistory.count > 12 { flickHistory.removeFirst() }
    }

    /// ⌫で1文字消したときに呼ぶ
    private func noteDelete() {
        guard let last = flickHistory.popLast() else { pendingDeleted.removeAll(); return }
        if Date().timeIntervalSince(lastDeleteTime) > Self.retypeWindow { pendingDeleted.removeAll() }
        pendingDeleted.insert(last, at: 0)
        lastDeleteTime = Date()
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
            var q = p
            if settings.autoCorrect {
                // まず全体のずれで仮のキーを決め、そのキーのずれ（全体＋キーごとの差）で位置を直してから、あらためて判定する
                let first = hit(CGPoint(x: p.x - touchOffset.x, y: p.y - touchOffset.y))
                let o = first.map { effectiveOffset($0.def.id) } ?? touchOffset
                q = CGPoint(x: p.x - o.x, y: p.y - o.y)
            }
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
                    self.startCursorEdgeRepeat(a)
                    self.setNeedsDisplay()
                }
            }
            active[t] = a
            onPress?()
        }
        setNeedsDisplay()
    }

    /// 改行・確定キーの上に指が来たら時刻を覚え、少し止めたら「取消」を出す
    private func trackCancel(_ a: Active, _ p: CGPoint) {
        var skip = a.cursorMode || a.repeated || a.key.def.isNumberPad
        if case .newline = a.key.def.action { skip = true }
        var over = false
        if !skip, let k = hit(p), case .newline = k.def.action { over = true }
        if over {
            if a.cancelSince == nil {
                a.cancelSince = Date()
                a.cancelTimer?.invalidate()
                a.cancelTimer = Timer.scheduledTimer(withTimeInterval: Self.cancelHold + 0.02, repeats: false) { [weak self] _ in
                    self?.setNeedsDisplay()
                }
            }
        } else if a.cancelSince != nil {
            a.cancelSince = nil
            a.cancelTimer?.invalidate()
        }
    }

    /// 空白のカーソル移動：指が左右の端に近いあいだは、動かさなくても少しずつ進める（右端のキーでは右へ動かす場所がないため）
    private func startCursorEdgeRepeat(_ a: Active) {
        a.timer?.invalidate()
        a.timer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self, weak a] _ in
            guard let self, let a, a.cursorMode else { return }
            let edge: CGFloat = 36
            if a.current.x > self.bounds.width - edge, a.current.x - a.start.x > 10 {
                self.onCursor?(1)
            } else if a.current.x < edge, a.start.x - a.current.x > 10 {
                self.onCursor?(-1)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let stepPt: CGFloat = 2.2 * CGFloat(KeyboardSettings.ptPerMM)
        for t in touches {
            guard let a = active[t] else { continue }
            let p = t.location(in: self)
            a.current = p
            if a.key.def.isNumberPad { trackNumber(a, p) }
            trackCancel(a, p)
            if a.key.def.flickChars != nil, !a.key.def.isNumberPad {
                let d = direction(a.key, from: a.start, to: p)
                if d != a.lastDir { a.lastDir = d; onFlickChange?() }
            }
            if case .space = a.key.def.action, !a.cursorMode {
                // 長押しを待たずに横へ大きく動かしたときも、カーソル移動にする
                if abs(p.x - a.start.x) > stepPt * 1.5 {
                    a.timer?.invalidate()
                    a.cursorMode = true
                    a.cursorAnchorX = a.start.x
                    a.cursorAnchorY = a.start.y
                    startCursorEdgeRepeat(a)
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
            a.cancelTimer?.invalidate()
            if a.repeated { resetFlickHistory() }   // 長押しで連続して消したときは、対応が取れないので学習しない
            if a.key.def.isNumberPad {
                // タップだけでは何も入れない。2回続けてタップすると数字を固定し、固定中にタップすると解除する
                if a.numberStage == nil {
                    let now = Date()
                    if numberLocked {
                        numberLocked = false
                    } else if now.timeIntervalSince(lastNumberTap) < 0.4 {
                        numberLocked = true
                    }
                    lastNumberTap = numberLocked ? .distantPast : now
                }
                if a.numberStage != nil, let k = numberKey(at: t.location(in: self)),
                   let digit = Self.numberKeyDigits[k.def.id] {
                    onKey?(KeyDef(id: "digit" + digit, label: digit, action: .direct([digit, "", "", "", ""])), .tap)
                }
                continue
            }
            // 数字の固定中は、かなキーのタップがそのまま数字になる
            if numberLocked, let digit = Self.numberKeyDigits[a.key.def.id] {
                onKey?(KeyDef(id: "digit" + digit, label: digit, action: .direct([digit, "", "", "", ""])), .tap)
                continue
            }
            if !a.repeated && !a.cursorMode {
                let end = t.location(in: self)
                // フリックして改行・確定キーの上で少し止めてから離したら、キャンセル（何も入れない）
                if let since = a.cancelSince, Date().timeIntervalSince(since) >= Self.cancelHold,
                   let over = hit(end), case .newline = over.def.action {
                    continue
                }
                let dir = direction(a.key, from: a.start, to: end)
                if dir == .tap, a.key.def.isCharacter { learnOffset(a.start, a.key) }
                if a.key.def.isCharacter {
                    noteFlick(a.key, dir: dir, from: a.start, to: end)
                } else if a.key.def.isDelete && dir == .tap {
                    noteDelete()
                } else {
                    resetFlickHistory()
                }
                onKey?(a.key.def, dir)
            }
        }
        setNeedsDisplay()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            if let a = active.removeValue(forKey: t) { a.timer?.invalidate(); a.cancelTimer?.invalidate() }
        }
        setNeedsDisplay()
    }
}
