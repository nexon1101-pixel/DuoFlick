import Foundation

/// アプリ本体の設定画面から、キーボードへ渡す設定。
/// 無料の署名では App Groups が使えないので、JSON にしてクリップボード経由で渡す（キーボードが開いたときに読み込む）。
struct SharedPrefs: Codable, Equatable {
    var iosLayout: Bool = true
    var lockWhileComposing: Bool = true
    var typoCorrection: Bool = false
    var toggleTap: Bool = false
    var haptics: Bool = true
    var autoCorrect: Bool = true
    var labelScale: Double = 1.0

    static let marker = "DUOFLICK-SETTINGS:"

    func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self), let s = String(data: data, encoding: .utf8) else { return "" }
        return Self.marker + s
    }

    static func decode(_ text: String) -> SharedPrefs? {
        guard text.hasPrefix(marker) else { return nil }
        let json = String(text.dropFirst(marker.count))
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SharedPrefs.self, from: data)
    }
}
