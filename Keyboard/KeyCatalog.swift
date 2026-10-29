import Foundation

enum FlickDirection: Int {
    case tap = 0, left, up, right, down
}

/// 文字の種類
enum InputMode: String, Codable {
    case kana, alpha, number

    var next: InputMode {
        switch self {
        case .kana: return .alpha
        case .alpha: return .number
        case .number: return .kana
        }
    }

    /// 文字種キーに表示する、次の文字種の名前
    var switchLabel: String {
        switch next {
        case .kana: return "あいう"
        case .alpha: return "ABC"
        case .number: return "☆123"
        }
    }
}

enum KeyAction {
    case kana([String])   // かな：[タップ, 左, 上, 右, 下]。変換の対象になる
    case direct([String]) // 英字・数字・記号：そのまま入力する
    case modifier         // 小゛゜
    case caseToggle       // a/A：直前の英字の大文字・小文字を入れ替える
    case delete
    case space
    case newline
    case undo             // ↺：確定の取り消し
    case modeSwitch
    case settings
    case nextKeyboard
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
        if case .nextKeyboard = action { return "globe" }
        return nil
    }

    var isDelete: Bool {
        if case .delete = action { return true }
        return false
    }

    /// ⚙キー（上フリックで定型文、右フリックでクリップボード）
    var isSettings: Bool {
        if case .settings = action { return true }
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

    static func leftColumn(_ mode: InputMode) -> [KeyDef?] {
        [
            KeyDef(id: "undo", label: "↺", action: .undo),
            KeyDef(id: "settings", label: "⚙", action: .settings),
            KeyDef(id: "mode", label: mode.switchLabel, action: .modeSwitch),
            KeyDef(id: "globe", label: "", action: .nextKeyboard),
        ]
    }

    static func functionColumn(_ mode: InputMode) -> [KeyDef?] {
        [
            KeyDef(id: "delete", label: "⌫", action: .delete),
            KeyDef(id: "space", label: mode == .kana ? "空白" : "space", action: .space),
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

    // 英字（iPhoneの英字フリックと同じ並び）
    private static let alphaColumns: [[KeyDef?]] = [
        [direct("at", ["@", "#", "/", "&", "_"], label: "@#/&_"),
         direct("ghi", ["g", "h", "i", "", ""], label: "GHI"),
         direct("pqrs", ["p", "q", "r", "s", ""], label: "PQRS"),
         KeyDef(id: "case", label: "a/A", action: .caseToggle)],
        [direct("abc", ["a", "b", "c", "", ""], label: "ABC"),
         direct("jkl", ["j", "k", "l", "", ""], label: "JKL"),
         direct("tuv", ["t", "u", "v", "", ""], label: "TUV"),
         direct("quote", ["'", "\"", "(", ")", ""], label: "'\"()")],
        [direct("def", ["d", "e", "f", "", ""], label: "DEF"),
         direct("mno", ["m", "n", "o", "", ""], label: "MNO"),
         direct("wxyz", ["w", "x", "y", "z", ""], label: "WXYZ"),
         direct("dot", [".", ",", "?", "!", ""], label: ".,?!")],
    ]

    // 数字と記号
    private static let numberColumns: [[KeyDef?]] = [
        [direct("n1", ["1", "☆", "♪", "→", ""], label: "1"),
         direct("n4", ["4", "○", "*", "・", ""], label: "4"),
         direct("n7", ["7", "「", "」", ":", ""], label: "7"),
         direct("paren", ["(", ")", "[", "]", ""], label: "()[]")],
        [direct("n2", ["2", "¥", "$", "€", ""], label: "2"),
         direct("n5", ["5", "+", "×", "÷", ""], label: "5"),
         direct("n8", ["8", "〒", "々", "〆", ""], label: "8"),
         direct("n0", ["0", "〜", "…", "", ""], label: "0")],
        [direct("n3", ["3", "%", "°", "#", ""], label: "3"),
         direct("n6", ["6", "<", "=", ">", ""], label: "6"),
         direct("n9", ["9", "^", "|", "\\", ""], label: "9"),
         direct("ndot", [".", ",", "-", "/", ""], label: ".,-/")],
    ]

    static func columns(_ mode: InputMode) -> [[KeyDef?]] {
        let middle: [[KeyDef?]]
        switch mode {
        case .kana: middle = kanaColumns
        case .alpha: middle = alphaColumns
        case .number: middle = numberColumns
        }
        return [leftColumn(mode)] + middle + [functionColumn(mode)]
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
