import Foundation
import Combine

struct UserWord: Codable, Identifiable, Equatable {
    var id = UUID()
    var word: String
    var reading: String   // ひらがな
    /// "ios" のとき、iOSのユーザ辞書から取り込んだ語（取り込むたびに入れ替える）
    var source: String? = nil
}

/// ユーザー辞書。アプリ本体とキーボードで共有の保存先に持つ（SideStore で App Groups が使えるとき）。
final class UserDictionaryStore: ObservableObject {
    private static let key = "DuoFlick.userDictionary.v1"
    @Published private(set) var words: [UserWord] = []
    var onChange: (() -> Void)?

    init() { load() }

    private func load() {
        if let data = SharedStore.defaults.data(forKey: Self.key),
           let list = try? JSONDecoder().decode([UserWord].self, from: data) {
            words = list
        } else {
            words = []
        }
    }

    /// 保存先から読み直す（アプリ本体で変えたとき）
    func reload() {
        load()
        onChange?()
    }

    func add(word: String, reading: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = reading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !r.isEmpty else { return }
        words.removeAll { $0.word == w && $0.reading == r }
        words.insert(UserWord(word: w, reading: r), at: 0)
        save()
    }

    /// 読みをひらがなにそろえる。かな以外が混ざっていれば nil
    static func normalizedReading(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = t.applyingTransform(.hiraganaToKatakana, reverse: true) ?? t
        let isKana = !r.isEmpty && r.unicodeScalars.allSatisfy { (0x3041...0x3096).contains($0.value) || $0.value == 0x30FC }
        return isKana ? r : nil
    }

    /// iOSのユーザ辞書（単語とよみ）で入れ替える（洗い替え）。前に取り込んだ語を消してから、かなのよみがあるものを足す。
    /// 自分で登録した語は消さない。足した数を返す。iOSから1語も取れなかったときは、何も変えずに 0 を返す
    func importSystem(_ items: [(word: String, reading: String)]) -> Int {
        guard !items.isEmpty else { return 0 }
        words.removeAll { $0.source == "ios" }
        var count = 0
        for item in items {
            let w = item.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !w.isEmpty, let r = Self.normalizedReading(item.reading), w != r else { continue }
            if words.contains(where: { $0.word == w && $0.reading == r }) { continue }
            words.append(UserWord(word: w, reading: r, source: "ios"))
            count += 1
        }
        save()
        return count
    }

    func remove(_ item: UserWord) {
        words.removeAll { $0.id == item.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(words) {
            SharedStore.defaults.set(data, forKey: Self.key)
        }
        onChange?()
    }
}
