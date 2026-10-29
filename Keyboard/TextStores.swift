import Foundation
import Combine
import UIKit

/// 文字列の一覧を保存する（定型文・クリップボード履歴）
class TextListStore: ObservableObject {
    @Published private(set) var items: [String] = []
    /// 固定した項目（上に出し、件数の上限で消えない）
    @Published private(set) var pinned: Set<String> = []
    private let key: String
    private let limit: Int

    init(key: String, limit: Int) {
        self.key = key
        self.limit = limit
        items = UserDefaults.standard.stringArray(forKey: key) ?? []
        pinned = Set(UserDefaults.standard.stringArray(forKey: key + ".pinned") ?? [])
        sortPinnedFirst()
    }

    func add(_ text: String) {
        let t = text.trimmingCharacters(in: .newlines)
        guard !t.isEmpty else { return }
        items.removeAll { $0 == t }
        items.insert(t, at: 0)
        sortPinnedFirst()
        // 上限を超えたら、固定していないものを古い順に消す
        while items.count > limit, let i = items.lastIndex(where: { !pinned.contains($0) }) {
            items.remove(at: i)
        }
        save()
    }

    func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        pinned.remove(items[index])
        items.remove(at: index)
        save()
    }

    func togglePin(_ text: String) {
        if pinned.contains(text) { pinned.remove(text) } else { pinned.insert(text) }
        sortPinnedFirst()
        save()
    }

    func removeAll() {
        items = items.filter { pinned.contains($0) }
        save()
    }

    private func sortPinnedFirst() {
        let p = items.filter { pinned.contains($0) }
        let rest = items.filter { !pinned.contains($0) }
        items = p + rest
    }

    private func save() {
        UserDefaults.standard.set(items, forKey: key)
        UserDefaults.standard.set(Array(pinned), forKey: key + ".pinned")
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
