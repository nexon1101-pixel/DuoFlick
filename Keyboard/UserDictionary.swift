import Foundation
import Combine

/// 単語登録中の状態（読みはキーボードのかなキーで入力する）
final class RegisterModel: ObservableObject {
    @Published var word: String
    @Published var reading: String = ""
    init(word: String) { self.word = word }
}
