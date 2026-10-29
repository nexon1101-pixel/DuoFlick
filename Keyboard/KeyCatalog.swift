import Foundation

enum FlickDirection: Int {
    case tap = 0, left, up, right, down
}

enum KeyAction {
    case kana([String])   // [タップ, 左, 上, 右, 下]
    case modifier         // 小゛゜
    case delete
    case space
    case newline
    case cursorLeft
    case cursorRight
    case emoji
    case settings
    case nextKeyboard
}

struct KeyDef {
    let id: String
    let label: String
    let action: KeyAction
    var rowSpan: Int = 1

    var isKana: Bool {
        if case .kana = action { return true }
        return false
    }
}

enum KeyCatalog {
    private static func kana(_ id: String, _ chars: [String], label: String? = nil) -> KeyDef {
        KeyDef(id: id, label: label ?? chars[0], action: .kana(chars))
    }
    private static func kana(_ id: String, _ s: String) -> KeyDef {
        kana(id, s.map { String($0) })
    }

    static let leftColumn: [KeyDef?] = [
        KeyDef(id: "cursorLeft", label: "◀", action: .cursorLeft),
        KeyDef(id: "emoji", label: "😀", action: .emoji),
        KeyDef(id: "settings", label: "⚙", action: .settings),
        KeyDef(id: "globe", label: "🌐", action: .nextKeyboard),
    ]
    static let column1: [KeyDef?] = [
        kana("a", "あいうえお"),
        kana("ta", "たちつてと"),
        kana("ma", "まみむめも"),
        KeyDef(id: "mod", label: "小゛゜", action: .modifier),
    ]
    static let column2: [KeyDef?] = [
        kana("ka", "かきくけこ"),
        kana("na", "なにぬねの"),
        kana("ya", ["や", "「", "ゆ", "」", "よ"]),
        kana("wa", ["わ", "を", "ん", "ー", ""]),
    ]
    static let column3: [KeyDef?] = [
        kana("sa", "さしすせそ"),
        kana("ha", "はひふへほ"),
        kana("ra", "らりるれろ"),
        kana("punct", ["、", "。", "？", "！", ""], label: "、。?!"),
    ]
    static let functionColumn: [KeyDef?] = [
        KeyDef(id: "delete", label: "⌫", action: .delete),
        KeyDef(id: "space", label: "空白", action: .space),
        KeyDef(id: "newline", label: "改行", action: .newline, rowSpan: 2),
        nil,
    ]

    static var columns: [[KeyDef?]] {
        [leftColumn, column1, column2, column3, functionColumn]
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
