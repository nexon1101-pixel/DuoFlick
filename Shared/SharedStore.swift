import Foundation

/// アプリ本体とキーボードで設定を共有する保存先。
/// SideStore で入れたときは App Groups（共有の場所）が使えるので、そこに保存する。
/// 使えないとき（Sideloadly など）は、これまでどおりそれぞれのアプリの中に保存する。
enum SharedStore {
    /// 実際の App Group 名。SideStore は署名のときに、名前の末尾へチーム ID を付けるので、
    /// 自分に付けられた名前を、アプリに入っている署名の情報（embedded.mobileprovision）から読む。
    static let groupID: String? = {
        let url = Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision")
        guard let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)),
              start.lowerBound < end.upperBound,
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], options: [], format: nil) as? [String: Any],
              let ents = plist["Entitlements"] as? [String: Any],
              let groups = ents["com.apple.security.application-groups"] as? [String]
        else { return nil }
        return groups.first(where: { $0.hasPrefix("group.jp.wataru.duoflick") }) ?? groups.first
    }()

    /// 共有の場所が実際に使えるか（コンテナが取れるか）
    static let isShared: Bool = {
        guard let id = groupID else { return false }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) != nil
    }()

    /// 設定の保存先
    static let defaults: UserDefaults = {
        guard isShared, let id = groupID, let d = UserDefaults(suiteName: id) else { return .standard }
        migrate(into: d)
        return d
    }()

    /// 共有に切り替わった最初の一回だけ、これまでの保存先（DuoFlick.* の設定）を引き継ぐ
    private static func migrate(into d: UserDefaults) {
        let flag = "DuoFlick.sharedMigrated.v1"
        guard !d.bool(forKey: flag) else { return }
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() where key.hasPrefix("DuoFlick.") {
            if d.object(forKey: key) == nil { d.set(value, forKey: key) }
        }
        d.set(true, forKey: flag)
    }

    /// 状態の説明（アプリのホームに出す）
    static var statusText: String {
        if isShared { return "共有できています" }
        if groupID != nil { return "共有の場所が取れません" }
        return "共有は使えません（このアプリの中だけに保存）"
    }
}
