import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// 入力中のひらがなと変換候補を管理する。変換エンジンは azooKey（MIT License）を使う。
@MainActor
final class Composer {
    private(set) var composing = ComposingText()
    private(set) var candidates: [Candidate] = []
    /// 空白キーで選んでいる候補。nil のときはひらがなのまま。
    private(set) var selectedIndex: Int?

    /// 確定後に出す、次に続きそうな言葉
    private(set) var predictions: [PostCompositionPredictionCandidate] = []
    private var predictionBase: Candidate?

    /// ユーザー辞書の単語（変換エンジンを作ったときと、辞書を変えたときに渡す）
    var userWords: [UserWord] = [] {
        didSet { if converterReady { importUserWords() } }
    }

    private var converterReady = false
    private lazy var converter: KanaKanjiConverter = {
        let c = KanaKanjiConverter()
        c.sendToDicdataStore(.setRequestOptions(options))
        converterReady = true
        importUserWords(into: c)
        return c
    }()

    private lazy var options: ConvertRequestOptions = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("DuoFlickLearning", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return ConvertRequestOptions.withDefaultDictionary(
            N_best: 10,
            needTypoCorrection: false,
            requireJapanesePrediction: true,
            requireEnglishPrediction: false,
            keyboardLanguage: .ja_JP,
            learningType: .inputAndOutput,
            memoryDirectoryURL: dir,
            sharedContainerURL: dir,
            metadata: .init(versionString: "DuoFlick")
        )
    }()

    private func importUserWords() {
        importUserWords(into: converter)
    }

    private func importUserWords(into c: KanaKanjiConverter) {
        let elements = userWords.map {
            DicdataElement(word: $0.word, ruby: Self.katakana($0.reading),
                           cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -5)
        }
        c.sendToDicdataStore(.importDynamicUserDict(elements))
    }

    private static func katakana(_ s: String) -> String {
        s.applyingTransform(.hiraganaToKatakana, reverse: false) ?? s
    }

    var isEmpty: Bool { composing.isEmpty }
    var reading: String { composing.convertTarget }

    /// 文節を区切っているか（読みの途中までを変換している）
    private var isSegmented: Bool {
        composing.convertTargetCursorPosition < composing.convertTarget.count
    }

    /// 区切った位置より後ろの読み
    private var readingAfterSegment: String {
        String(composing.convertTarget.dropFirst(composing.convertTargetCursorPosition))
    }

    /// 入力欄に下線付きで表示する文字
    var markedText: String {
        if let i = selectedIndex, i < candidates.count {
            return candidates[i].text + readingAfterSegment
        }
        return composing.convertTarget
    }

    var candidateTexts: [String] { candidates.map(\.text) }
    var predictionTexts: [String] { predictions.map(\.text) }

    func clearPredictions() {
        predictions = []
        predictionBase = nil
        predictionPending = false
    }

    func insert(_ s: String) {
        clearPredictions()
        selectedIndex = nil
        // 文節を区切っていた場合も、入力は末尾に足す
        _ = composing.moveCursorFromCursorPosition(count: composing.convertTarget.count)
        composing.insertAtCursorPosition(s, inputStyle: .direct)
        markDirty()
    }

    /// 直前の1文字を別の形（濁点・小書きなど）に置き換える。置き換えたら true。
    func replaceLast(with s: String) -> Bool {
        guard !composing.isEmpty else { return false }
        selectedIndex = nil
        _ = composing.moveCursorFromCursorPosition(count: composing.convertTarget.count)
        composing.deleteBackwardFromCursorPosition(count: 1)
        composing.insertAtCursorPosition(s, inputStyle: .direct)
        markDirty()
        return true
    }

    func deleteBackward() {
        if selectedIndex != nil {
            // 候補を選んでいる途中なら、選択を解除してひらがなに戻す
            selectedIndex = nil
            return
        }
        _ = composing.moveCursorFromCursorPosition(count: composing.convertTarget.count)
        composing.deleteBackwardFromCursorPosition(count: 1)
        markDirty()
    }

    /// 文節の区切り位置を動かす（空白キー長押しで左右）
    func moveSegment(by count: Int) {
        guard !composing.isEmpty else { return }
        let moved = composing.moveCursorFromCursorPosition(count: count)
        // 区切りは1文字以上残す
        if composing.convertTargetCursorPosition == 0 {
            _ = composing.moveCursorFromCursorPosition(count: 1)
        }
        if moved != 0 {
            selectedIndex = nil
            markDirty()
        }
    }

    /// 空白キー：次の候補を選ぶ
    func selectNext() {
        refreshIfNeeded()
        guard !candidates.isEmpty else { return }
        if let i = selectedIndex {
            selectedIndex = (i + 1) % candidates.count
        } else {
            selectedIndex = 0
        }
    }

    /// 候補を確定する。確定した文字を返す。
    func commit(candidateAt index: Int) -> String? {
        guard index < candidates.count else { return nil }
        let c = candidates[index]
        composing.prefixComplete(composingCount: c.composingCount)
        selectedIndex = nil
        converter.updateLearningData(c)
        if composing.isEmpty {
            converter.stopComposition()
            candidates = []
            startPredictions(after: c)
        } else {
            converter.setCompletedData(c)
            // 残りの読みは区切りなしで変換し直す
            _ = composing.moveCursorFromCursorPosition(count: composing.convertTarget.count)
            refresh()
        }
        return c.text
    }

    /// 選んでいる候補（なければひらがな）で全部確定する
    func commitAll() -> String {
        var out = ""
        if let i = selectedIndex, let text = commit(candidateAt: i) {
            out += text
            if composing.isEmpty { return out }
        }
        out += composing.convertTarget
        reset()
        return out
    }

    /// 予測の候補を選んだ。入れる文字を返す。
    func choosePrediction(at index: Int) -> String? {
        guard index < predictions.count, let base = predictionBase else { return nil }
        let p = predictions[index]
        converter.updateLearningData(base, with: p)
        if p.isTerminal {
            clearPredictions()
        } else {
            startPredictions(after: p.join(to: base))
        }
        return p.text
    }

    /// 予測は確定の表示を先に済ませてから計算する（loadPredictionsIfNeeded で実行）
    private var predictionPending = false

    private func startPredictions(after c: Candidate) {
        predictionBase = c
        predictions = []
        predictionPending = true
    }

    func loadPredictionsIfNeeded() {
        guard predictionPending, let base = predictionBase, composing.isEmpty else { return }
        predictionPending = false
        let list = converter.requestPostCompositionPredictionCandidates(leftSideCandidate: base, options: options)
        predictions = Array(list.prefix(10))
    }

    /// 確定を取り消したとき、読みを入力中の状態に戻す
    func restore(reading: String) {
        reset()
        insert(reading)
    }

    func reset() {
        composing.stopComposition()
        if converterReady { converter.stopComposition() }
        candidates = []
        selectedIndex = nil
    }

    /// 辞書が読めているかを確かめる（調整バーの「変換の診断」で表示）
    func diagnostics() -> String {
        let fm = FileManager.default
        let dict = options.dictionaryResourceURL
        let louds = dict.appendingPathComponent("louds", isDirectory: true)
        let chid = louds.appendingPathComponent("charID.chid")
        let loudsCount = (try? fm.contentsOfDirectory(atPath: louds.path).count) ?? -1
        var lines: [String] = []
        lines.append("辞書フォルダ：\(fm.fileExists(atPath: dict.path) ? "あり" : "なし")")
        lines.append("louds：\(loudsCount)個　charID：\(fm.fileExists(atPath: chid.path) ? "あり" : "なし")")
        let chidText = (try? String(contentsOf: chid, encoding: .utf8)) ?? ""
        lines.append("charID：\(chidText.count)文字　「キ」\(chidText.contains("キ") ? "あり" : "なし")")
        let ki = louds.appendingPathComponent("キ.louds")
        let kiSize = (try? Data(contentsOf: ki).count) ?? -1
        lines.append("キ.louds：\(kiSize)バイト")

        var test = ComposingText()
        test.insertAtCursorPosition("きょう", inputStyle: .direct)
        let result = converter.requestCandidates(test, options: options).mainResults.prefix(5).map(\.text)
        converter.stopComposition()
        lines.append("候補（補正なし）：\(result.joined(separator: " / "))")

        var typoOptions = options
        typoOptions.needTypoCorrection = true
        let result2 = converter.requestCandidates(test, options: typoOptions).mainResults.prefix(5).map(\.text)
        converter.stopComposition()
        lines.append("候補（補正あり）：\(result2.joined(separator: " / "))")

        // 辞書を直接引く
        let store = DicdataStore(convertRequestOptions: options)
        let nodes = store.lookupDicdata(composingText: test, surfaceRange: (startIndex: 0, endIndexRange: nil), needTypoCorrection: false)
        let words = nodes.prefix(8).map { $0.data.word }
        lines.append("辞書を直接：\(nodes.count)件 \(words.joined(separator: " "))")
        lines.append(dict.path)
        return lines.joined(separator: "\n")
    }

    /// 学習内容を保存する（キーボードを閉じるとき）
    func save() {
        guard converterReady else { return }
        converter.sendToDicdataStore(.closeKeyboard)
    }

    /// 変換候補が今の読みに追いついていないか
    private(set) var needsRefresh = false

    /// 読みが変わったら、候補はいったん空にして後でまとめて変換する（打鍵のたびに変換すると重いため）
    private func markDirty() {
        candidates = []
        needsRefresh = true
    }

    func refreshIfNeeded() {
        guard needsRefresh else { return }
        refresh()
    }

    private func refresh() {
        needsRefresh = false
        guard !composing.isEmpty else {
            candidates = []
            if converterReady { converter.stopComposition() }
            return
        }
        let target = isSegmented ? composing.prefixToCursorPosition() : composing
        candidates = converter.requestCandidates(target, options: options).mainResults
    }
}
