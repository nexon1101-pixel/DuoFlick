import Foundation
import Combine

struct UserWord: Codable, Identifiable, Equatable {
    var id = UUID()
    var word: String
    var reading: String   // ひらがな
}

/// ユーザー辞書。キーボードの中だけに保存する（無料アカウントでは本体アプリと共有できないため）。
final class UserDictionaryStore: ObservableObject {
    private static let key = "DuoFlick.userDictionary.v1"
    @Published private(set) var words: [UserWord] = []
    var onChange: (() -> Void)?

    init() {
        if let data = SharedStore.defaults.data(forKey: Self.key),
           let list = try? JSONDecoder().decode([UserWord].self, from: data) {
            words = list
        }
    }

    func add(word: String, reading: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = reading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !r.isEmpty else { return }
        words.removeAll { $0.word == w && $0.reading == r }
        words.insert(UserWord(word: w, reading: r), at: 0)
        save()
    }

    /// iOSのユーザ辞書（単語とよみ）を取り込む。かなのよみがあるものだけ、まだなければ末尾に足す。足した数を返す
    func importSystem(_ items: [(word: String, reading: String)]) -> Int {
        var count = 0
        for item in items {
            let w = item.word.trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = item.reading.trimmingCharacters(in: .whitespacesAndNewlines)
            let r = raw.applyingTransform(.hiraganaToKatakana, reverse: true) ?? raw
            let isKana = !r.isEmpty && r.unicodeScalars.allSatisfy { (0x3041...0x3096).contains($0.value) || $0.value == 0x30FC }
            guard !w.isEmpty, isKana, w != r else { continue }
            if words.contains(where: { $0.word == w && $0.reading == r }) { continue }
            words.append(UserWord(word: w, reading: r))
            count += 1
        }
        if count > 0 { save() }
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

/// 単語登録中の状態（読みはキーボードのかなキーで入力する）
final class RegisterModel: ObservableObject {
    @Published var word: String
    @Published var reading: String = ""
    init(word: String) { self.word = word }
}
