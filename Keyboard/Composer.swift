import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// 入力中のひらがなと変換候補を管理する。変換エンジンは azooKey（MIT License）を使う。
@MainActor
final class Composer {
    private(set) var composing = ComposingText()
    private(set) var candidates: [Candidate] = []
    /// 空白キーで選んでいる候補。nil のときはひらがなのまま。
    private(set) var selectedIndex: Int?

    private lazy var converter = KanaKanjiConverter()
    private lazy var options: ConvertRequestOptions = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return ConvertRequestOptions.withDefaultDictionary(
            N_best: 10,
            requireJapanesePrediction: true,
            requireEnglishPrediction: false,
            keyboardLanguage: .ja_JP,
            learningType: .nothing,
            memoryDirectoryURL: dir,
            sharedContainerURL: dir,
            metadata: .init(versionString: "DuoFlick")
        )
    }()

    var isEmpty: Bool { composing.isEmpty }
    var reading: String { composing.convertTarget }

    /// 入力欄に下線付きで表示する文字
    var markedText: String {
        if let i = selectedIndex, i < candidates.count { return candidates[i].text }
        return composing.convertTarget
    }

    var candidateTexts: [String] { candidates.map(\.text) }

    func insert(_ s: String) {
        selectedIndex = nil
        composing.insertAtCursorPosition(s, inputStyle: .direct)
        refresh()
    }

    /// 直前の1文字を別の形（濁点・小書きなど）に置き換える。置き換えたら true。
    func replaceLast(with s: String) -> Bool {
        guard !composing.isEmpty else { return false }
        selectedIndex = nil
        composing.deleteBackwardFromCursorPosition(count: 1)
        composing.insertAtCursorPosition(s, inputStyle: .direct)
        refresh()
        return true
    }

    func deleteBackward() {
        if selectedIndex != nil {
            // 候補を選んでいる途中なら、選択を解除してひらがなに戻す
            selectedIndex = nil
            return
        }
        composing.deleteBackwardFromCursorPosition(count: 1)
        refresh()
    }

    /// 空白キー：次の候補を選ぶ
    func selectNext() {
        guard !candidates.isEmpty else { return }
        if let i = selectedIndex {
            selectedIndex = (i + 1) % candidates.count
        } else {
            selectedIndex = 0
        }
    }

    /// 候補を確定する。確定した文字と、まだ残っている読みがあるかを返す。
    func commit(candidateAt index: Int) -> String? {
        guard index < candidates.count else { return nil }
        let c = candidates[index]
        composing.prefixComplete(composingCount: c.composingCount)
        selectedIndex = nil
        if composing.isEmpty {
            converter.stopComposition()
            candidates = []
        } else {
            converter.setCompletedData(c)
            refresh()
        }
        return c.text
    }

    /// 選んでいる候補（なければひらがな）で全部確定する
    func commitAll() -> String {
        var out = ""
        if let i = selectedIndex, let text = commit(candidateAt: i) {
            out += text
        }
        out += composing.convertTarget
        reset()
        return out
    }

    /// 確定を取り消したとき、読みを入力中の状態に戻す
    func restore(reading: String) {
        reset()
        insert(reading)
    }

    func reset() {
        composing.stopComposition()
        converter.stopComposition()
        candidates = []
        selectedIndex = nil
    }

    private func refresh() {
        guard !composing.isEmpty else {
            candidates = []
            converter.stopComposition()
            return
        }
        candidates = converter.requestCandidates(composing, options: options).mainResults
    }
}
