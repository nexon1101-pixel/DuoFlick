import Foundation
import Combine
import UIKit

/// 文字列の一覧を保存する（定型文・クリップボード履歴）
class TextListStore: ObservableObject {
    @Published private(set) var items: [String] = []
    /// 固定した項目（上に出し、件数の上限で消えない）
    @Published private(set) var pinned: Set<String> = []
    private let key: String
    private let limitFn: () -> Int
    private var limit: Int { limitFn() }

    convenience init(key: String, limit: Int) {
        self.init(key: key, limitFn: { limit })
    }

    init(key: String, limitFn: @escaping () -> Int) {
        self.key = key
        self.limitFn = limitFn
        items = SharedStore.defaults.stringArray(forKey: key) ?? []
        pinned = Set(SharedStore.defaults.stringArray(forKey: key + ".pinned") ?? [])
        sortPinnedFirst()
    }

    /// 保存先から読み直す（アプリ本体で変えたとき）
    func reload() {
        items = SharedStore.defaults.stringArray(forKey: key) ?? []
        pinned = Set(SharedStore.defaults.stringArray(forKey: key + ".pinned") ?? [])
        sortPinnedFirst()
    }

    var onChange: (() -> Void)?

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
        SharedStore.defaults.set(items, forKey: key)
        SharedStore.defaults.set(Array(pinned), forKey: key + ".pinned")
        onChange?()
    }
}

final class PhraseStore: TextListStore {
    init() { super.init(key: "DuoFlick.phrases.v1", limitFn: { 100 }) }
}


/// クリップボード履歴の件数（設定）
enum ClipboardLimit {
    static let key = "DuoFlick.clipboardLimit.v1"
    static let choices = [10, 20, 30, 50, 100, 200]
    static var value: Int {
        let v = SharedStore.defaults.integer(forKey: key)
        return v > 0 ? v : 30
    }
}
