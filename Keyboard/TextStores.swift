import Foundation
import Combine
import UIKit

/// 文字列の一覧を保存する（定型文・クリップボード履歴）
class TextListStore: ObservableObject {
    @Published private(set) var items: [String] = []
    private let key: String
    private let limit: Int

    init(key: String, limit: Int) {
        self.key = key
        self.limit = limit
        items = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func add(_ text: String) {
        let t = text.trimmingCharacters(in: .newlines)
        guard !t.isEmpty else { return }
        items.removeAll { $0 == t }
        items.insert(t, at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
        save()
    }

    func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        save()
    }

    func removeAll() {
        items = []
        save()
    }

    private func save() {
        UserDefaults.standard.set(items, forKey: key)
    }
}

final class PhraseStore: TextListStore {
    init() { super.init(key: "DuoFlick.phrases.v1", limit: 100) }
}

/// クリップボードの履歴。キーボードが開いている間にコピーされたものだけを記録する。
final class ClipboardStore: TextListStore {
    private var lastChangeCount = UIPasteboard.general.changeCount

    init() { super.init(key: "DuoFlick.clipboard.v1", limit: 30) }

    /// コピーされた内容が変わっていれば履歴に足す（フルアクセスが必要）
    func capture() {
        let pb = UIPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard pb.hasStrings, let s = pb.string else { return }
        add(s)
    }
}
