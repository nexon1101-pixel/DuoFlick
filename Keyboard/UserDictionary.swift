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
        if let data = UserDefaults.standard.data(forKey: Self.key),
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

    func remove(_ item: UserWord) {
        words.removeAll { $0.id == item.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(words) {
            UserDefaults.standard.set(data, forKey: Self.key)
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
