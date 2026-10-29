import Foundation
import CoreGraphics

enum FlickDirection: Int {
    case tap = 0, left, up, right, down
}

/// 文字の種類
enum InputMode: String, Codable {
    case kana      // かなフリック
    case qwerty    // 英字（パソコンと同じ並び）
    case symbol    // 数字と記号
    case symbol2   // そのほかの記号

    /// 文字種キー（かな⇄英字）で切り替える先
    var next: InputMode { self == .kana ? .qwerty : .kana }

    /// 文字種キーに表示する、切り替え先の名前
    var switchLabel: String { self == .kana ? "ABC" : "あいう" }
}

enum KeyAction {
    case kana([String])   // かな：[タップ, 左, 上, 右, 下]。変換の対象になる
    case direct([String]) // 英字・数字・記号：そのまま入力する
    case modifier         // 小゛゜
    case shift            // 英字の大文字（2回続けて押すと固定）
    case layer(InputMode) // 英字・記号の面を切り替える
    case numberPad        // 数字キー：右上で0〜4、右下で5〜9
    case gripSwitch       // 片手持ち⇄両手持ちの設定を切り替える
    case widthToggle      // 英字キーボードの日本語（ローマ字かな）⇄英字。パソコンの全角／半角キーと同じ
    case delete
    case space
    case newline
    case modeSwitch
    case settings
    case nextKeyboard
    case paste            // クリップボードの文字をそのまま貼り付ける
    case cursorRight      // カーソルを右へ（入力中は文節を右へ）
    case undoCommit       // 確定の取り消し（↺）
    case splitKeys        // かなを左右に分ける（両手持ちの分割）
}

struct KeyDef {
    let id: String
    let label: String
    let action: KeyAction
    var rowSpan: Int = 1

    /// フリックの文字（ガイドに表示し、方向で選ぶ）
    var flickChars: [String]? {
        switch action {
        case .kana(let c), .direct(let c): return c
        default: return nil
        }
    }

    /// 文字を入れるキー（明るい色で描く）
    var isCharacter: Bool { flickChars != nil }

    /// 文字の代わりに描く記号（SF Symbols の名前）
    var symbol: String? {
        switch action {
        case .nextKeyboard: return "globe"
        case .shift: return "shift"
        case .delete: return "delete.left"
        case .paste: return "doc.on.clipboard"
        case .cursorRight: return "arrow.right"
        case .undoCommit: return "arrow.counterclockwise"
        case .splitKeys: return "rectangle.split.2x1"
        case .gripSwitch: return label == "片手" ? "iphone" : "ipad"
        default: return nil
        }
    }

    var isDelete: Bool {
        if case .delete = action { return true }
        return false
    }

    /// フリックで別の働きをするキー（地球儀：上で設定、左で定型文、右でクリップボード）
    var isSettings: Bool {
        switch action {
        case .settings, .nextKeyboard: return true
        default: return false
        }
    }

    var isNumberPad: Bool {
        if case .numberPad = action { return true }
        return false
    }
}

enum KeyCatalog {
    private static func split(_ s: String) -> [String] {
        var a = s.map { String($0) }
        while a.count < 5 { a.append("") }
        return a
    }
    private static func kana(_ id: String, _ s: String) -> KeyDef {
        let c = split(s)
        return KeyDef(id: id, label: c[0], action: .kana(c))
    }
    private static func kana(_ id: String, _ chars: [String], label: String) -> KeyDef {
        KeyDef(id: id, label: label, action: .kana(chars))
    }
    private static func direct(_ id: String, _ chars: [String], label: String) -> KeyDef {
        KeyDef(id: id, label: label, action: .direct(chars))
    }

    static func leftColumn(_ mode: InputMode, grip: Grip) -> [KeyDef?] {
        [
            KeyDef(id: "number", label: "123", action: .numberPad),
            KeyDef(id: "globe", label: "", action: .nextKeyboard),
            KeyDef(id: "mode", label: mode.switchLabel, action: .modeSwitch),
            KeyDef(id: "grip", label: grip == .one ? "片手" : "両手", action: .gripSwitch),
        ]
    }

    static func functionColumn(_ mode: InputMode) -> [KeyDef?] {
        [
            KeyDef(id: "delete", label: "⌫", action: .delete),
            KeyDef(id: "space", label: "空白", action: .space),
            KeyDef(id: "newline", label: "改行", action: .newline, rowSpan: 2),
            nil,
        ]
    }

    // かな（iPhoneのかなフリックと同じ並び）
    private static let kanaColumns: [[KeyDef?]] = [
        [kana("a", "あいうえお"), kana("ta", "たちつてと"), kana("ma", "まみむめも"),
         KeyDef(id: "mod", label: "小゛゜", action: .modifier)],
        [kana("ka", "かきくけこ"), kana("na", "なにぬねの"),
         kana("ya", ["や", "「", "ゆ", "」", "よ"], label: "や"),
         kana("wa", ["わ", "を", "ん", "ー", ""], label: "わ")],
        [kana("sa", "さしすせそ"), kana("ha", "はひふへほ"), kana("ra", "らりるれろ"),
         kana("punct", ["、", "。", "？", "！", ""], label: "、。?!")],
    ]

    static func columns(_ mode: InputMode, grip: Grip) -> [[KeyDef?]] {
        [leftColumn(mode, grip: grip)] + kanaColumns + [functionColumn(mode)]
    }

    /// iOS標準に合わせた配置（内側画面の片手持ち）。左に4つのキー、間は候補の一覧、右にかなと⌫・空白・改行・123
    static let iosWeights: [CGFloat] = [1, 3.4, 1, 1, 1, 1]
    static func iosColumns(_ mode: InputMode, grip: Grip) -> [[KeyDef?]] {
        let left: [KeyDef?] = [
            KeyDef(id: "cursorR", label: "", action: .cursorRight),
            KeyDef(id: "undo", label: "", action: .undoCommit),
            KeyDef(id: "split", label: "", action: .splitKeys),
            KeyDef(id: "mode", label: mode.switchLabel, action: .modeSwitch),
            KeyDef(id: "globe", label: "", action: .nextKeyboard),
        ]
        let fn: [KeyDef?] = [
            KeyDef(id: "delete", label: "⌫", action: .delete),
            KeyDef(id: "space", label: "空白", action: .space),
            KeyDef(id: "newline", label: "改行", action: .newline),
            KeyDef(id: "number", label: "123", action: .numberPad),
        ]
        return [left, [nil, nil, nil, nil]] + kanaColumns + [fn]
    }

    /// 両手持ち用：かなと⌫・空白・改行を左右に1組ずつ置き、真ん中を空ける。123・地球儀・ABC・両手のキーは右端に1列だけ
    static func splitColumns(_ mode: InputMode, grip: Grip) -> [[KeyDef?]] {
        let half = kanaColumns + [functionColumn(mode)]
        let gap: [KeyDef?] = [nil, nil, nil, nil]
        return half + [gap] + half + [leftColumn(mode, grip: grip)]
    }

    // MARK: - 英字・記号（iPhone標準の英字キーボードと同じ並び）

    /// 1行分のキー。weight は幅の比率
    typealias Row = [(def: KeyDef, weight: CGFloat)]

    private static func letters(_ s: String) -> Row {
        s.map { c in (def: KeyDef(id: "q_" + String(c), label: String(c), action: .direct([String(c), "", "", "", ""])), weight: CGFloat(1)) }
    }

    private static func item(_ def: KeyDef, _ weight: CGFloat) -> (def: KeyDef, weight: CGFloat) {
        (def: def, weight: weight)
    }

    static func qwertyRows(_ mode: InputMode) -> [Row] {
        let delete = item(KeyDef(id: "delete", label: "⌫", action: .delete), 1.5)
        let bottom: Row = [
            (def: KeyDef(id: "layer", label: mode == .qwerty ? "123" : "ABC",
                         action: .layer(mode == .qwerty ? .symbol : .qwerty)), weight: 1.2),
            (def: KeyDef(id: "mode", label: "あいう", action: .modeSwitch), weight: 1.2),
            (def: KeyDef(id: "paste", label: "貼付", action: .paste), weight: 1.2),
            (def: KeyDef(id: "width", label: "A", action: .widthToggle), weight: 1.2),
            (def: KeyDef(id: "space", label: "space", action: .space), weight: 3.2),
            (def: KeyDef(id: "newline", label: "改行", action: .newline), weight: 2.0),
        ]
        switch mode {
        case .symbol:
            return [
                letters("1234567890"),
                letters("-/:;()¥&@\""),
                [item(KeyDef(id: "layer2", label: "#+=", action: .layer(.symbol2)), 1.5)] + letters(".,?!'") + [delete],
                bottom,
            ]
        case .symbol2:
            return [
                letters("[]{}#%^*+="),
                letters("_\\|~<>$€£•"),
                [item(KeyDef(id: "layer2", label: "123", action: .layer(.symbol)), 1.5)] + letters(".,?!'") + [delete],
                bottom,
            ]
        default:
            return [
                letters("qwertyuiop"),
                letters("asdfghjkl"),
                [item(KeyDef(id: "shift", label: "⇧", action: .shift), 1.5)] + letters("zxcvbnm") + [delete],
                bottom,
            ]
        }
    }

    private static let cycles: [[String]] = [
        "かが", "きぎ", "くぐ", "けげ", "こご", "さざ", "しじ", "すず", "せぜ", "そぞ",
        "ただ", "ちぢ", "つっづ", "てで", "とど", "はばぱ", "ひびぴ", "ふぶぷ", "へべぺ", "ほぼぽ",
        "あぁ", "いぃ", "うぅゔ", "えぇ", "おぉ", "やゃ", "ゆゅ", "よょ", "わゎ",
    ].map { $0.map { String($0) } }

    /// 小゛゜キーで、直前の文字を次の形（濁点・半濁点・小書き）に切り替える
    static func modified(_ c: String) -> String? {
        for cycle in cycles {
            if let i = cycle.firstIndex(of: c) {
                return cycle[(i + 1) % cycle.count]
            }
        }
        return nil
    }
}
