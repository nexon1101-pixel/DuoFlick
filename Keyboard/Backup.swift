import Foundation

/// 設定・登録した単語・定型文・選んだ語の記憶を、1つの文字列（JSON）にまとめて書き出し、戻す。
/// 覚えた変換（エンジンの学習データ）と、クリップボードの履歴（パスワードなどが入りうる）は含めない。
enum Backup {
    private static let prefix = "DuoFlick."
    private static let excluded = ["DuoFlick.clipboard"]

    private static func isTarget(_ key: String) -> Bool {
        key.hasPrefix(prefix) && !excluded.contains { key.hasPrefix($0) }
    }

    static func makeJSON() -> String? {
        var values: [String: String] = [:]
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() where isTarget(key) {
            if let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) {
                values[key] = data.base64EncodedString()
            }
        }
        let object: [String: Any] = [
            "app": "DuoFlick",
            "version": 1,
            "date": ISO8601DateFormatter().string(from: Date()),
            "defaults": values,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 戻した項目の数。バックアップの形でなければ nil
    static func restore(from text: String) -> Int? {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["app"] as? String == "DuoFlick",
              let values = object["defaults"] as? [String: String] else { return nil }
        var count = 0
        for (key, base64) in values where isTarget(key) {
            guard let raw = Data(base64Encoded: base64),
                  let value = try? PropertyListSerialization.propertyList(from: raw, options: [], format: nil) else { continue }
            UserDefaults.standard.set(value, forKey: key)
            count += 1
        }
        return count
    }
}
