import Foundation
import UIKit
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
        // SKK 辞書から作った同梱の辞書（user.louds など）。エンジンは sharedContainerURL の中の「user」を読む（読み取りだけ）
        let skkDict = Bundle.main.url(forResource: "SkkDict", withExtension: nil) ?? dir
        return ConvertRequestOptions.withDefaultDictionary(
            N_best: 10,
            needTypoCorrection: false,
            requireJapanesePrediction: true,
            requireEnglishPrediction: false,
            keyboardLanguage: .ja_JP,
            learningType: .inputAndOutput,
            memoryDirectoryURL: dir,
            sharedContainerURL: skkDict,
            metadata: .init(versionString: "DuoFlick")
        )
    }()

    private func importUserWords() {
        importUserWords(into: converter)
    }

    private func importUserWords(into c: KanaKanjiConverter) {
        // 最初から入れておく単語は、ユーザー辞書より少し低い順位で足す
        let builtin = BuiltinWords.list.map {
            DicdataElement(word: $0.word, ruby: Self.katakana($0.reading),
                           cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -7)
        }
        let elements = userWords.map {
            DicdataElement(word: $0.word, ruby: Self.katakana($0.reading),
                           cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -5)
        }
        c.sendToDicdataStore(.importDynamicUserDict(builtin + elements))
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

    // MARK: - ライブ変換

    /// ライブ変換：入力中の文字を、ひらがなではなく変換した形で出す。中身（読み）は今までどおりひらがなで持つ
    var liveConversion = false
    /// AIモデル（Zenzai）で変換するか。モデルのファイルがあるときだけ働く
    var zenzai = false
    /// カーソルより前の文章（Zenzai に文脈として渡す）
    var leftContext = ""
    /// 直近の変換で、AIに渡した文脈（診断用）
    private(set) var lastZenzContext: String? = nil
    /// 大きいモデル（small）を使うか
    var zenzaiHigh = false
    private static func zenzURL(high: Bool) -> URL? {
        let dir = high ? "small" : "xsmall"
        let u = Bundle.main.bundleURL.appendingPathComponent("Zenz/\(dir)/ggml-model-Q5_K_M.gguf", isDirectory: false)
        if FileManager.default.fileExists(atPath: u.path) { return u }
        // 大きいモデルがないときは、小さいモデルを使う
        let small = Bundle.main.bundleURL.appendingPathComponent("Zenz/xsmall/ggml-model-Q5_K_M.gguf", isDirectory: false)
        return FileManager.default.fileExists(atPath: small.path) ? small : nil
    }
    /// いまの設定を反映した、変換のときの設定
    private func requestOptionsForConvert() -> ConvertRequestOptions {
        var o = options
        if zenzai { lastZenzContext = leftContext }   // 診断で見せる（実際の変換で渡した文脈）
        if zenzai, let url = Self.zenzURL(high: zenzaiHigh) {
            o.zenzaiMode = .on(
                weight: url,
                inferenceLimit: 10,
                personalizationMode: nil,
                versionDependentMode: .v3(.init(leftSideContext: leftContext.isEmpty ? nil : leftContext))
            )
        }
        return o
    }

    /// 変換した文を文節に分けたもの
    struct LiveClause {
        var reading: String
        var text: String
        var candidate: Candidate
        /// 選び直した候補（選んでいなければ nil）
        var chosen: Candidate?
        var shown: String { chosen?.text ?? text }
    }
    private(set) var liveClauses: [LiveClause] = []
    /// liveClauses を作ったときの読み
    private var liveReading = ""
    /// 空白の長押しで、変換せずひらがなのまま見せている間
    private(set) var readingMode = false
    /// 文全体の先頭の候補が candidates の何番目か
    private var liveBestIndex = 0
    /// 選び直している文節の番号（nil なら文全体）
    private(set) var focusClause: Int?
    /// 選び直している文節の候補（0番目は元の候補）
    private var clauseAlts: [Candidate] = []

    /// いまの読みで、変換した形を出せるか（打ちたての分は、あとに足して出す）
    private var liveUsable: Bool {
        liveConversion && !isSegmented && !liveClauses.isEmpty && composing.convertTarget.hasPrefix(liveReading)
    }

    /// 先頭の候補を文節に分ける（エンジンの makePrefixClauseCandidate で、先頭の文節を取り出すのを繰り返す）
    private func buildLive() {
        liveClauses = []
        liveReading = ""
        focusClause = nil
        clauseAlts = []
        guard liveConversion, !isSegmented else { return }
        let reading = composing.convertTarget
        let chars = Array(reading)
        guard !chars.isEmpty,
              let bi = candidates.firstIndex(where: { $0.rubyCount == chars.count && !$0.data.isEmpty }) else { return }
        var rest = candidates[bi].data[...]
        var pos = 0
        var out: [LiveClause] = []
        while !rest.isEmpty {
            var c = Candidate.makePrefixClauseCandidate(data: rest)
            if c.data.isEmpty {
                c = Candidate(text: rest.map(\.word).joined(), value: -5,
                              composingCount: .surfaceCount(rest.reduce(0) { $0 + $1.ruby.count }),
                              lastMid: 501, data: Array(rest))
            }
            let n = c.data.reduce(0) { $0 + $1.ruby.count }
            guard n > 0, pos + n <= chars.count else { return }
            out.append(LiveClause(reading: String(chars[pos..<pos + n]), text: c.text, candidate: c, chosen: nil))
            pos += n
            rest = rest.dropFirst(c.data.count)
        }
        guard pos == chars.count else { return }
        // 読みが1文字のときは、ライブ変換しない（ひらがなのまま見せる。「を」→「ヺ」のような変な形も防ぐ）
        if chars.count == 1 { return }
        liveClauses = out
        liveReading = reading
        liveBestIndex = bi
    }

    /// ライブ変換で、帯に小さく出す読み。文節を選び直している間は、その文節の読み
    var readingLabel: String? {
        guard liveConversion, !composing.isEmpty else { return nil }
        if let k = focusClause, k < liveClauses.count { return liveClauses[k].reading }
        return composing.convertTarget
    }

    /// 読みのひらがなのまま確定する（帯の左端の読みを押したとき）。文節を選び直している間は、その文節だけひらがなにする。
    /// 文節の場合は nil（確定はしない）
    func commitReadingAsIs() -> String? {
        guard liveConversion, !composing.isEmpty else { return nil }
        if focusClause != nil {
            if let i = clauseAlts.firstIndex(where: { $0.text == readingLabel }) { _ = chooseClauseAlt(i) }
            return nil
        }
        let text = composing.convertTarget
        reset()
        return text
    }

    /// 変換せず、読みのひらがなのまま見せる（空白の長押し）。確定はしない
    func showReadingOnly() {
        guard !composing.isEmpty else { return }
        readingMode = true
        selectedIndex = nil
        focusClause = nil
    }

    /// 帯の先頭に、前に選んだ記号などを出しているか
    private var frontExtra: Bool { extraAt == 0 && !extras.isEmpty }

    /// 選び直している文節を、入力欄の下線の文字の中で選択して見せる範囲
    var markedHighlight: NSRange? {
        guard let k = focusClause, liveUsable, k < liveClauses.count else { return nil }
        let before = liveClauses[..<k].map(\.shown).joined()
        return NSRange(location: (before as NSString).length, length: (liveClauses[k].shown as NSString).length)
    }

    /// 文節の選び直し：→（空白の長押しの右）で右の文節へ、空白の長押しの左で左の文節へ。最初は先頭（左へなら末尾）の文節
    private func moveClauseFocus(_ count: Int) {
        let n = liveClauses.count
        let next: Int
        if let k = focusClause {
            next = min(max(k + count, 0), n - 1)
        } else {
            next = count > 0 ? 0 : n - 1
        }
        guard next != focusClause else { return }
        focusClause = next
        loadClauseAlts()
    }

    /// 選び直す文節の候補を集める（その文節の読みだけを変換する）
    private func loadClauseAlts() {
        guard let k = focusClause, k < liveClauses.count else { return }
        let cl = liveClauses[k]
        var ct = ComposingText()
        ct.insertAtCursorPosition(cl.reading, inputStyle: .direct)
        var o = options
        o.needTypoCorrection = false
        let found = converter.requestCandidates(ct, options: o).mainResults
        var list: [Candidate] = [cl.candidate]
        var seen: Set<String> = [cl.candidate.text]
        let n = cl.reading.count
        for c in found where c.rubyCount == n && !seen.contains(c.text) {
            seen.insert(c.text)
            list.append(c)
            if list.count >= 40 { break }
        }
        // 変換エンジンの候補にないとき用に、ひらがなとカタカナも足す
        for t in [cl.reading, Self.katakana(cl.reading)] where !seen.contains(t) {
            seen.insert(t)
            list.append(Candidate(text: t, value: -20, composingCount: .surfaceCount(n), lastMid: 501,
                                  data: [DicdataElement(word: t, ruby: Self.katakana(cl.reading),
                                                        cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -20)]))
        }
        clauseAlts = list
        if let ch = cl.chosen, let i = list.firstIndex(where: { $0.text == ch.text }) {
            selectedIndex = i
        } else {
            selectedIndex = 0
        }
    }

    /// 選び直している文節の候補を選ぶ。選び直しの最中でなければ false
    func chooseClauseAlt(_ i: Int) -> Bool {
        guard let k = focusClause, k < liveClauses.count, i >= 0, i < clauseAlts.count else { return false }
        selectedIndex = i
        liveClauses[k].chosen = i == 0 ? nil : clauseAlts[i]
        return true
    }

    /// 文節を選び直した結果も含めて、全部確定する
    private func commitLive() -> String {
        var out = liveClauses.map(\.shown).joined()
        // 変換が追いついていない打ちたての分は、そのまま足す
        out += String(composing.convertTarget.dropFirst(liveReading.count))
        for cl in liveClauses {
            converter.updateLearningData(cl.chosen ?? cl.candidate)
            if let ch = cl.chosen { remember(ch) }
        }
        scheduleSave()
        let last = liveClauses.last.map { $0.chosen ?? $0.candidate }
        reset()
        if let last { startPredictions(after: last) }
        return out
    }

    /// 帯の番号（変換エンジンの候補の番号から、入れた候補の分だけずれる）
    private func displayIndex(forCandidate ci: Int) -> Int {
        let p = min(extraAt, candidates.count)
        return ci < p || extras.isEmpty ? ci : ci + extras.count
    }

    /// 入力欄に下線付きで表示する文字
    var markedText: String {
        if readingMode { return composing.convertTarget }
        if frontExtra, focusClause == nil, selectedIndex == nil { return extras[0] }
        if focusClause == nil, let i = selectedIndex, i < displayCount {
            if let ci = candidateIndex(forDisplay: i) {
                return candidates[ci].text + readingAfterSegment
            }
            return extraText(forDisplay: i) ?? composing.convertTarget
        }
        if liveUsable {
            return liveClauses.map(\.shown).joined() + String(composing.convertTarget.dropFirst(liveReading.count))
        }
        return composing.convertTarget
    }

    var candidateTexts: [String] { focusClause != nil ? clauseAlts.map(\.text) : withExtra(candidates.map(\.text)) }
    /// 一覧に出す候補（多すぎると重いので200個まで）
    var listTexts: [String] { focusClause != nil ? clauseAlts.map(\.text) : withExtra(candidates.prefix(200).map(\.text)) }

    // MARK: - 英字の候補（ローマ字かな入力で、打った英字のまま入れたいとき）

    /// 打った英字そのまま。ローマ字だけで打ち、読みを区切っていないときだけ出す
    private var rawRoman = ""
    private var rawValid = true
    /// 変換エンジンの候補のあいだに入れる候補（打った英字、数字の全角・漢数字）と、入れる位置
    private var extras: [String] = []
    private var extraAt = 2
    /// 選んだ記憶を残せる種類の追加候補か（日付・時刻と、打った英字は対象外）
    private var extrasRememberable = false

    private func withExtra(_ texts: [String]) -> [String] {
        guard !extras.isEmpty else { return texts }
        var t = texts
        t.insert(contentsOf: extras, at: min(extraAt, t.count))
        return t
    }

    private var displayCount: Int { focusClause != nil ? clauseAlts.count : candidates.count + extras.count }

    /// 帯の番号から変換候補の番号を求める（入れた候補なら nil）
    private func candidateIndex(forDisplay i: Int) -> Int? {
        guard focusClause == nil, !extras.isEmpty else { return i }
        let p = min(extraAt, candidates.count)
        if i < p { return i }
        if i < p + extras.count { return nil }
        return i - extras.count
    }

    /// 帯の番号が、入れた候補のものならその文字
    private func extraText(forDisplay i: Int) -> String? {
        let p = min(extraAt, candidates.count)
        guard i >= p, i - p < extras.count else { return nil }
        return extras[i - p]
    }

    /// 句読点を1つだけ打ったときの、ほかの形（半角・全角）の候補
    private static let punctuationVariants: [Character: [String]] = [
        "、": ["，", ",", "､"], "。": ["．", ".", "｡"], "？": ["?"], "！": ["!"], "「": ["｢"], "」": ["｣"],
    ]

    /// ひらがな（と長音）だけか
    static func isHiragana(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { (0x3041...0x3096).contains($0.value) || $0.value == 0x30FC }
    }

    /// 読みで出す顔文字
    private static let kaomoji: [String: [String]] = [
        "かお": ["(^_^)", "(・ω・)", "(´・ω・`)", "(^o^)"],
        "かおもじ": ["(^_^)", "(・ω・)", "(´・ω・`)", "(^o^)"],
        "えがお": ["(^_^)", "(＾▽＾)", "(*^‿^*)", "ヽ(´▽`)/"],
        "わらい": ["(^o^)", "(≧▽≦)", "(*´▽`*)", "(^▽^)"],
        "わらう": ["(^o^)", "(≧▽≦)", "(*´▽`*)", "(^▽^)"],
        "うれしい": ["(*^▽^*)", "ヽ(*´▽`*)ノ", "(≧▽≦)", "☆*:.｡. o(≧▽≦)o .｡.:*☆"],
        "たのしい": ["(*^▽^*)", "ヽ(´▽`)/", "♪(๑ᴖ◡ᴖ๑)♪"],
        "やったー": ["ヽ(´▽`)/", "\\(^o^)/", "☆ヽ(▽⌒*)"],
        "ばんざい": ["\\(^o^)/", "ヽ(´▽`)/", "＼(^o^)／"],
        "しょぼん": ["(´・ω・`)", "(´；ω；`)", "(._.)", "(｡•́︿•̀｡)"],
        "かなしい": ["(´；ω；`)", "(T_T)", "(；＿；)", "(´・ω・`)"],
        "なき": ["(T_T)", "(；＿；)", "(ToT)", "･ﾟ･(ﾉД`)･ﾟ･"],
        "なみだ": ["(T_T)", "(；＿；)", "(ToT)"],
        "ごめん": ["m(_ _)m", "(._.)", "orz", "(´；ω；`)"],
        "ごめんなさい": ["m(_ _)m", "(._.)", "orz"],
        "すみません": ["m(_ _)m", "(._.)", "orz"],
        "ありがとう": ["m(_ _)m", "(*^‿^*)", "(^_^)/", "ヽ(´▽`)/"],
        "おねがい": ["m(_ _)m", "(´・ω・`)", "(人´∀`)", "(*´ω`*)"],
        "おつかれ": ["(*´ω`*)", "(´ー｀)", "(._.)", "ヽ(´ー｀)ノ"],
        "おつかれさま": ["(*´ω`*)", "(´ー｀)", "(._.)", "ヽ(´ー｀)ノ"],
        "すき": ["(*´ω`*)", "(๑♡⌓♡๑)", "(*^^*)♡", "(´∀｀)♡"],
        "だいすき": ["(*´ω`*)♡", "(๑♡⌓♡๑)", "(*^^*)♡", "ヽ(*´▽`*)ノ♡"],
        "はーと": ["♡", "♥", "❤", "💕"],
        "ふぁいと": ["(ง •̀_•́)ง", "ヽ(`Д´)ノ", "ｶﾞﾝﾊﾞ(๑•̀ㅂ•́)و✧", "(`･ω･´)"],
        "がんばる": ["(ง •̀_•́)ง", "(`･ω･´)", "ヽ(`Д´)ノ", "(๑•̀ㅂ•́)و✧"],
        "おやすみ": ["(-_-)zzz", "(´-ω-`)", "( ˘ω˘ )ｽﾔｧ", "(_ _).｡o○"],
        "ねむい": ["(-_-)zzz", "(´-ω-`)", "( ˘ω˘ )ｽﾔｧ", "(´～｀)ﾑﾆｬﾑﾆｬ"],
        "びっくり": ["Σ(・□・;)", "(°o°)", "(◎_◎;)", "Σ(ﾟДﾟ)"],
        "おどろき": ["Σ(・□・;)", "(°o°)", "(◎_◎;)", "Σ(ﾟДﾟ)"],
        "てれ": ["(*´ω`*)", "(〃ﾉωﾉ)", "(//▽//)", "(´∀｀*)ﾎﾟｯ"],
        "はずかしい": ["(*´ω`*)", "(〃ﾉωﾉ)", "(//▽//)", "(´∀｀*)ﾎﾟｯ"],
        "ぷんぷん": ["(｀へ´)", "(`Д´)", "(# ﾟДﾟ)", "ヽ(`Д´)ﾉ"],
        "おこ": ["(｀へ´)", "(`Д´)", "(# ﾟДﾟ)", "ヽ(`Д´)ﾉ"],
        "いかり": ["(｀へ´)", "(`Д´)", "(# ﾟДﾟ)", "ヽ(`Д´)ﾉ"],
        "どや": ["(´∀｀)v", "( ･´ω･`)ﾄﾞﾔｧ", "(￣ー￣)ﾆﾔﾘ", "(`・ω・´)ﾄﾞﾔ"],
        "にやり": ["(￣ー￣)ﾆﾔﾘ", "(｀∀´)", "(・∀・)ﾆﾔﾆﾔ"],
        "つかれた": ["(´ー｀)", "(._.)", "orz", "(；´Д｀)"],
        "ぐったり": ["(´ー｀)", "orz", "(；´Д｀)", "(_ _|||)"],
        "まいった": ["orz", "(´；ω；`)", "(；´Д｀)"],
        "はてな": ["(・・？)", "(?_?)", "(´･_･`)?", "(・_・?)"],
        "うーん": ["(´ー｀)", "(-_-)", "(・_・?)", "(´･_･`)"],
        "ぴーす": ["(^_^)v", "✌", "(＾▽＾)v", "ヽ(´▽`)/"],
        "ぎゃー": ["Σ(ﾟДﾟ)", "((((；ﾟДﾟ))))", "(((( ；ﾟДﾟ)))))"],
        "こわい": ["((((；ﾟДﾟ))))", "(((( ；ﾟДﾟ)))))", "(；ﾟДﾟ)"],
        "ねこ": ["(=^･ω･^=)", "ฅ(＾・ω・＾ฅ)", "(^・ω・^)", "🐱"],
        "くま": ["ʕ•ᴥ•ʔ", "ʕ ·ᴥ·ʔ", "🐻"],
        "うさぎ": ["(๑•ᴗ•๑)", "(\\(・x・)/)", "🐰"],
        "いぬ": ["∪･ω･∪", "U・ᴥ・U", "🐶"],
        "ほっこり": ["(*´ω`*)", "(´ー`)", "( ´ω` )", "(*^^*)"],
        "しらんぷり": ["(・・)", "( ˘•ω•˘ )", "(´-ω-`)"],
        "やれやれ": ["┐(´д`)┌", "┐(´～`)┌", "(´ー｀)"],
        "ふぅ": ["(´ー｀)ﾌｩ", "(´-ω-`)", "( ´ー`)=3"],
        "にこにこ": ["(＾▽＾)", "(*^▽^*)", "ニコニコ(*^^*)", "(´∀｀)"],
        "ええー": ["(；ﾟДﾟ)", "Σ(ﾟДﾟ)", "(´ﾟдﾟ`)"],
        "ずこー": ["ヽ(´Д｀;)ﾉ", "(ノд`)", "orz"],
        "しくしく": ["(´；ω；`)", "(T_T)", "(；＿；)"],
        "うえーん": ["(T_T)", "･ﾟ･(ﾉД`)･ﾟ･", "(´；ω；`)"],
        "きらきら": ["✨", "☆彡", "(*´▽`*)✨", "⭐"],
        "ぐっど": ["(๑•̀ㅂ•́)و✧", "b(^_^)d", "(^_^)b", "👍"],
        "おっけー": ["(^_^)b", "(๑•̀ㅂ•́)و✧", "ヽ(´▽`)/", "OK👌"],
        "よろしく": ["m(_ _)m", "(*^^*)", "(^_^)/", "ヨロシク(｀･ω･´)ゞ"],
        "おはよう": ["(^o^)/", "ヽ(´▽`)/", "(*´ω`*)", "☀"],
        "こんにちは": ["(^o^)/", "ヽ(´▽`)/", "(＾▽＾)/"],
        "こんばんは": ["(^o^)/", "(*´ω`*)", "🌙"],
        "ばいばい": ["(^_^)/~~", "ヾ(・ω・`)ﾉ", "(´▽`)ﾉｼ", "(*´ω`*)ﾉｼ"],
        "じゃね": ["(^_^)/~~", "ヾ(・ω・`)ﾉ", "(´▽`)ﾉｼ"],
        "しーっ": ["( ˘ω˘ )シー", "(・ε・)", "(´-ω-`)"],
        "ないしょ": ["( ˘ω˘ )シー", "(・ε・)", "(´-ω-`)"],
        "てへぺろ": ["(๑>•̀๑)ﾃﾍﾍﾟﾛ", "(*ﾉω・*)ﾃﾍ", "(・ω<)☆"],
        "らぶ": ["(*^^*)♡", "ヽ(*´▽`*)ノ♡", "(๑♡⌓♡๑)", "💕"],
    ]

    /// 数字だけの読みの、全角と漢数字の候補
    private static func numberVariants(_ s: String) -> [String] {
        var out: [String] = []
        // 4けた以上は、3けたごとのカンマ区切り（例：1000 → 1,000）
        if s.count >= 4, !s.hasPrefix("0"), s.count <= 18 {
            var groups: [String] = []
            var rest = Substring(s)
            while rest.count > 3 { groups.insert(String(rest.suffix(3)), at: 0); rest = rest.dropLast(3) }
            groups.insert(String(rest), at: 0)
            out.append(groups.joined(separator: ","))
        }
        out.append(String(s.unicodeScalars.compactMap { UnicodeScalar($0.value + 0xFEE0) }.map { Character($0) }))
        let digits = ["〇", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        out.append(s.compactMap { Int(String($0)) }.map { digits[$0] }.joined())
        if s.count <= 16, !(s.hasPrefix("0") && s.count > 1), let n = UInt64(s), n > 0 {
            out.append(kanjiNumber(n))
        }
        return out
    }

    /// 位取りの漢数字（例：2024 → 二千二十四）
    private static func kanjiNumber(_ n: UInt64) -> String {
        let one = ["", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        let small = ["", "十", "百", "千"]
        let div = [1, 10, 100, 1000]
        let big = ["", "万", "億", "兆", "京"]
        var groups: [Int] = []
        var x = n
        while x > 0 { groups.append(Int(x % 10000)); x /= 10000 }
        var result = ""
        for gi in stride(from: groups.count - 1, through: 0, by: -1) where groups[gi] > 0 {
            var part = ""
            for pos in stride(from: 3, through: 0, by: -1) {
                let d = (groups[gi] / div[pos]) % 10
                if d == 0 { continue }
                part += (d == 1 && pos > 0) ? small[pos] : one[d] + small[pos]
            }
            result += part + big[gi]
        }
        return result
    }

    /// 消したあとの読みに合う、打った英字の長さに合わせ直す
    private func syncRaw() {
        guard rawValid else { return }
        let target = composing.convertTarget
        var k = rawRoman.count
        while k >= 0 {
            let p = String(rawRoman.prefix(k))
            var t = ComposingText()
            t.insertAtCursorPosition(p, inputStyle: .roman2kana)
            if t.convertTarget == target { rawRoman = p; return }
            k -= 1
        }
        rawValid = false
    }
    var predictionTexts: [String] { predictions.map(\.text) }

    /// 以前に選んだ語から、その読みを探す（選んだ文字を再変換するとき）
    func readingChosen(for word: String) -> String? {
        chosen.first(where: { $0.value.contains(word) })?.key
    }

    func clearPredictions() {
        predictions = []
        predictionBase = nil
        predictionPending = false
    }

    /// roman が true なら、ローマ字としてかなに直しながら入れる（英字キーボードの日本語入力）
    func insert(_ s: String, roman: Bool = false) {
        clearPredictions()
        selectedIndex = nil
        // 入力が空から始まるときは、前に打った英字の記録を捨てる（確定や全削除のあとに残っていた）
        if composing.isEmpty { rawRoman = ""; rawValid = true }
        // 文節を区切っていた場合も、入力は末尾に足す
        _ = composing.moveCursorFromCursorPosition(count: composing.convertTarget.count)
        composing.insertAtCursorPosition(s, inputStyle: roman ? .roman2kana : .direct)
        if roman || (!s.isEmpty && s.allSatisfy { $0.isASCII && $0.isLetter }) {
            rawRoman += s
        } else {
            rawValid = false
        }
        markDirty()
    }

    /// 直前の1文字を別の形（濁点・小書きなど）に置き換える。置き換えたら true。
    func replaceLast(with s: String) -> Bool {
        guard !composing.isEmpty else { return false }
        selectedIndex = nil
        _ = composing.moveCursorFromCursorPosition(count: composing.convertTarget.count)
        composing.deleteBackwardFromCursorPosition(count: 1)
        composing.insertAtCursorPosition(s, inputStyle: .direct)
        rawValid = false
        markDirty()
        return true
    }

    func deleteBackward() {
        if focusClause != nil {
            // 文節を選び直している途中なら、選び直しを終える（選んだ文節はそのまま）
            focusClause = nil
            clauseAlts = []
            selectedIndex = nil
            return
        }
        if selectedIndex != nil {
            // 候補を選んでいる途中なら、選択を解除してひらがなに戻す
            selectedIndex = nil
            return
        }
        _ = composing.moveCursorFromCursorPosition(count: composing.convertTarget.count)
        composing.deleteBackwardFromCursorPosition(count: 1)
        syncRaw()
        markDirty()
    }

    /// 文節の区切り位置を動かす（空白キー長押しで左右）
    func moveSegment(by count: Int) {
        guard !composing.isEmpty else { return }
        readingMode = false
        if liveConversion {
            refreshIfNeeded()
            if !liveClauses.isEmpty, liveReading == composing.convertTarget {
                moveClauseFocus(count)
                return
            }
        }
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
        readingMode = false
        refreshIfNeeded()
        guard displayCount > 0 else { return }
        if focusClause != nil {
            _ = chooseClauseAlt(((selectedIndex ?? 0) + 1) % displayCount)
            return
        }
        // ライブ変換では、先頭の候補がもう出ているので、最初の空白で次の候補へ進む
        if liveConversion, selectedIndex == nil, !liveClauses.isEmpty, displayCount > 1 {
            // 最初に出ているライブ変換の形が1つ目、空白で2つ目（帯の左から2番目）になる
            selectedIndex = 1
            return
        }
        if let i = selectedIndex {
            selectedIndex = (i + 1) % displayCount
        } else {
            selectedIndex = 0
        }
    }

    /// 候補を確定する。確定した文字を返す。
    func commit(candidateAt index: Int) -> String? {
        guard focusClause == nil, index < displayCount else { return nil }
        guard let ci = candidateIndex(forDisplay: index) else {
            // 打った英字のまま確定する
            let text = extraText(forDisplay: index) ?? composing.convertTarget
            rememberExtra(text)
            reset()
            return text
        }
        let c = candidates[ci]
        composing.prefixComplete(composingCount: c.composingCount)
        selectedIndex = nil
        converter.updateLearningData(c)
        remember(c)
        scheduleSave()
        if composing.isEmpty {
            converter.stopComposition()
            candidates = []
            startPredictions(after: c)
        } else {
            rawValid = false
            converter.setCompletedData(c)
            // 残りの読みは区切りなしで変換し直す
            _ = composing.moveCursorFromCursorPosition(count: composing.convertTarget.count)
            refresh()
        }
        return c.text
    }

    /// 選んでいる候補（なければひらがな）で全部確定する
    func commitAll() -> String {
        if readingMode {
            let t = composing.convertTarget
            reset()
            return t
        }
        if frontExtra, focusClause == nil, selectedIndex == nil { selectedIndex = 0 }
        if liveUsable, focusClause != nil || selectedIndex == nil {
            return commitLive()
        }
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
        scheduleSave()
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
        liveClauses = []
        liveReading = ""
        focusClause = nil
        clauseAlts = []
        rawRoman = ""
        rawValid = true
        extras = []
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

        // AI（Zenzai）：設定、モデルのファイル、いまの文脈、同じ読みをAIありなしで変換した結果
        lines.append("――AI（Zenzai）――")
        lines.append("設定：\(zenzai ? "オン" : "オフ")　高精度：\(zenzaiHigh ? "オン" : "オフ")")
        for m in ["xsmall", "small"] {
            let u = Bundle.main.bundleURL.appendingPathComponent("Zenz/\(m)/ggml-model-Q5_K_M.gguf")
            let size = ((try? fm.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.intValue ?? -1
            lines.append("\(m)：\(size < 0 ? "なし" : "\(size / 1_000_000)MB")")
        }
        lines.append("いまの文脈：「\(leftContext)」（\(leftContext.count)文字。設定画面を開いているときは空）")
        if let c = lastZenzContext {
            lines.append("直近の変換で渡した文脈：「\(c)」（\(c.count)文字）")
        } else {
            lines.append("直近の変換で渡した文脈：まだ変換していない")
        }
        var zt = ComposingText()
        zt.insertAtCursorPosition("かいとう", inputStyle: .direct)
        let ctx = leftContext.isEmpty ? "冷凍食品の" : leftContext
        if let url = Self.zenzURL(high: zenzaiHigh) {
            // 点検の回数（inferenceLimit）と、候補を多く出す設定（rich）を変えて、同じ読みを変換する
            for (limit, rich) in [(1, false), (3, false), (10, false), (10, true)] {
                var zo = options
                zo.zenzaiMode = .on(weight: url, inferenceLimit: limit, requestRichCandidates: rich, personalizationMode: nil,
                                    versionDependentMode: .v3(.init(leftSideContext: ctx)))
                let t0 = Date()
                let on = converter.requestCandidates(zt, options: zo).mainResults.prefix(5).map(\.text)
                let sec = Date().timeIntervalSince(t0)
                converter.stopComposition()
                lines.append("AIあり 回数\(limit)\(rich ? " rich" : "")（\(String(format: "%.2f", sec))秒）：\(on.joined(separator: " / "))")
            }
            lines.append("文脈：「\(ctx)」　状態：\(converter.zenzStatus)")
            // モデルそのものが働いているかの確認：文脈のつづきの1文字を、モデルに直接予想させる
            var po = options
            po.zenzaiMode = .on(weight: url, inferenceLimit: 1, personalizationMode: nil,
                                versionDependentMode: .v3(.init(leftSideContext: ctx)))
            let nexts = converter.predictNextCharacter(leftSideContext: ctx, count: 6, options: po)
            lines.append("モデルが予想する「\(ctx)」のつづき：" + (nexts.isEmpty ? "なし（モデルが働いていない）"
                : nexts.map { "\($0.character)(\(Int($0.value * 100))%)" }.joined(separator: " ")))
            let nexts2 = converter.predictNextCharacter(leftSideContext: "今日は天気が", count: 6, options: po)
            lines.append("モデルが予想する「今日は天気が」のつづき：" + (nexts2.isEmpty ? "なし"
                : nexts2.map { "\($0.character)(\(Int($0.value * 100))%)" }.joined(separator: " ")))
        } else {
            lines.append("モデルのファイルが見つからないため、AIは使われていません")
        }
        let off = converter.requestCandidates(zt, options: options).mainResults.prefix(5).map(\.text)
        converter.stopComposition()
        lines.append("かいとう（AIなし）：\(off.joined(separator: " / "))")
        return lines.joined(separator: "\n")
    }

    /// 「きょう」「いま」で出す日付・時刻
    private static func dateTimeCandidates(for reading: String) -> [String] {
        let now = Date()
        func format(_ pattern: String) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "ja_JP")
            f.calendar = Calendar(identifier: .gregorian)
            f.dateFormat = pattern
            return f.string(from: now)
        }
        if reading == "きょう" {
            return [format("yyyy年M月d日"), format("M月d日（E）")]
        }
        return [format("HH:mm"), format("H時m分")]
    }

    /// 覚えた変換（エンジンの学習と、選んだ語の記憶）を消す。設定・登録単語・定型文は消さない
    func resetLearning() {
        saveTask?.cancel()
        chosen = [:]
        SharedStore.defaults.removeObject(forKey: Self.chosenKey)
        var o = options
        o.shouldResetMemory = true
        converter.sendToDicdataStore(.setRequestOptions(o))
        converter.sendToDicdataStore(.setRequestOptions(options))
    }

    /// 学習内容を保存する（キーボードを閉じるとき、と確定の3秒後）
    func save() {
        saveTask?.cancel()
        guard converterReady else { return }
        converter.sendToDicdataStore(.closeKeyboard)
    }

    /// 確定のあと少し待って保存する（キーボードが閉じる前に終了させられても、覚えた語が残るように）
    private var saveTask: Task<Void, Never>?
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    // MARK: 選んだ語の記憶（読み → 選んだ順。エンジンの学習だけでは順位が上がりにくいので、こちらで先頭に出す）

    private static let chosenKey = "DuoFlick.chosen.v1"
    private var chosen: [String: [String]] = (SharedStore.defaults.dictionary(forKey: Composer.chosenKey) as? [String: [String]]) ?? [:]

    private func readingKey(_ c: Candidate) -> String {
        c.data.map(\.ruby).joined()
    }

    /// 変換エンジンの候補ではない候補（句読点の半角・全角、数字の形、顔文字）を選んだとき、同じ読みの記憶に入れる
    private func rememberExtra(_ text: String) {
        guard extrasRememberable, extras.contains(text) else { return }
        let reading = composing.convertTarget
        let key = reading.applyingTransform(.hiraganaToKatakana, reverse: false) ?? reading
        var list = chosen[key] ?? []
        list.removeAll { $0 == text }
        list.insert(text, at: 0)
        chosen[key] = Array(list.prefix(5))
        SharedStore.defaults.set(chosen, forKey: Self.chosenKey)
    }

    private func remember(_ c: Candidate) {
        let key = readingKey(c)
        guard !key.isEmpty else { return }
        var list = chosen[key] ?? []
        list.removeAll { $0 == c.text }
        list.insert(c.text, at: 0)
        chosen[key] = Array(list.prefix(5))
        if chosen.count > 4000 {
            for k in Array(chosen.keys.prefix(500)) where k != key { chosen.removeValue(forKey: k) }
        }
        SharedStore.defaults.set(chosen, forKey: Self.chosenKey)
    }

    /// いちばん上の候補と同じ読みで、前に選んだ語があれば、新しい順に先頭へ出す
    private func prioritizeChosen(_ list: [Candidate]) -> [Candidate] {
        guard let top = list.first else { return list }
        let key = readingKey(top)
        guard let texts = chosen[key], !texts.isEmpty else { return list }
        var front: [Candidate] = []
        for t in texts {
            if let c = list.first(where: { $0.text == t && readingKey($0) == key }) { front.append(c) }
        }
        guard !front.isEmpty else { return list }
        let used = Set(front.map(\.text))
        let rest = list.filter { !(used.contains($0.text) && readingKey($0) == key) }
        if zenzai, !leftContext.isEmpty, front.first?.text != top.text {
            // AIが前の文章を見て選んだ先頭は残し、前に選んだ語はそのすぐ後ろに出す
            // （前に選んだ語を先頭にすると、文脈に合わない語がいつも先頭に来てしまう）
            let topKept = front.filter { $0.text == top.text && readingKey($0) == key }
            let others = front.filter { !($0.text == top.text && readingKey($0) == key) }
            let head = topKept.isEmpty ? [top] : topKept
            return head + others + rest.filter { !($0.text == top.text && readingKey($0) == key) }
        }
        return front + rest
    }

    /// 変換候補が今の読みに追いついていないか
    private(set) var needsRefresh = false
    /// 打ち間違いを直した候補も出すか（設定で切り替える）
    var typoCorrection = false

    /// 読みが変わったら、後でまとめて変換する（打鍵のたびに変換すると重いため）。
    /// 変換が終わるまでは前の候補を出したままにして、帯がちらつかないようにする。
    private func markDirty() {
        readingMode = false
        needsRefresh = true
        focusClause = nil
        clauseAlts = []
    }

    /// 古い候補を押したとき：変換し直して、同じ文字の候補があればその番号を返す
    func freshIndex(forStale index: Int) -> Int? {
        let before = candidateTexts
        guard index < before.count else { return nil }
        let text = before[index]
        refreshIfNeeded()
        return candidateTexts.firstIndex { $0 == text }
    }

    func refreshIfNeeded() {
        guard needsRefresh else { return }
        refresh()
    }

    private func refresh() {
        needsRefresh = false
        guard !composing.isEmpty else {
            candidates = []
            extras = []
            liveClauses = []
            liveReading = ""
            focusClause = nil
            if converterReady { converter.stopComposition() }
            return
        }
        let target = isSegmented ? composing.prefixToCursorPosition() : composing
        var requestOptions = requestOptionsForConvert()
        requestOptions.needTypoCorrection = typoCorrection
        var found = converter.requestCandidates(target, options: requestOptions).mainResults
        // 絵文字の候補は出さない（顔文字は、読みから足す処理をやめた）
        found = found.filter { c in !c.text.unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000) } }
        if liveConversion || zenzai, !isSegmented {
            // ライブ変換・AI変換：読み全体の候補を、読みの続きを補った予測より先に並べる（帯の先頭を、下線の文字と同じにする）。
            // 読みをそのままカタカナ・ひらがなにしただけの候補は、ほかの候補のあとに回す
            let reading = composing.convertTarget
            let n = reading.count
            let kata = reading.applyingTransform(.hiraganaToKatakana, reverse: false) ?? reading
            let exact = found.filter { $0.rubyCount == n && !$0.data.isEmpty }
            // 伸ばす棒（ー）を波線（〜 ～ ~）にしただけの候補（うーん→ウ~ン）も、読みそのままとみなす
            // 濁点・半濁点をつけただけの形（ヺ、を゛ など）も、読みそのままとみなす
            func norm(_ t: String) -> String {
                var v = String.UnicodeScalarView()
                for u in t.decomposedStringWithCanonicalMapping.unicodeScalars
                where ![0x3099, 0x309A, 0x309B, 0x309C].contains(u.value) { v.append(u) }
                return String(String(v).map { "〜～~∼".contains($0) ? "ー" : $0 })
            }
            let nk = norm(kata), nr = norm(reading)
            func isPlain(_ c: Candidate) -> Bool { let t = norm(c.text); return t == nk || t == nr }
            let plain = exact.filter(isPlain)
            let others = exact.filter { !isPlain($0) }
            let rest = found.filter { !($0.rubyCount == n && !$0.data.isEmpty) }
            found = others + plain + rest
        }
        candidates = prioritizeChosen(found)
        buildLive()
        extras = []
        guard !isSegmented else { return }
        let reading = composing.convertTarget
        let have = Set(candidates.map(\.text))
        extrasRememberable = false
        if reading == "きょう" || reading == "いま" {
            // 今日の日付と今の時刻（変換エンジンの候補にない形だけ足す）
            extraAt = 1
            for v in Self.dateTimeCandidates(for: reading) where !have.contains(v) { extras.append(v) }
        } else if reading.count == 1, let c = reading.first, let list = Self.punctuationVariants[c] {
            extraAt = 1
            extrasRememberable = true
            for v in list where !have.contains(v) { extras.append(v) }
        } else if reading.allSatisfy({ $0.isASCII && $0.isNumber }) {
            // 数字だけ：全角と漢数字を、先頭の候補のすぐあとに出す
            extraAt = 1
            extrasRememberable = true
            for v in Self.numberVariants(reading) where !have.contains(v) && !extras.contains(v) { extras.append(v) }
        } else if rawValid, !rawRoman.isEmpty, rawRoman.allSatisfy({ $0.isASCII }),
                  rawRoman != reading {
            extraAt = 2   // 3番目以降（先頭の候補の邪魔にならないように）
            extras = [rawRoman]
            // 先頭だけ大文字にした形も（例：hello → Hello）
            let cap = rawRoman.prefix(1).uppercased() + rawRoman.dropFirst()
            if cap != rawRoman, !have.contains(cap) { extras.append(cap) }
        } else if reading.count <= 24, Composer.isHiragana(reading) {
            // ひらがなだけ：半角カナを、候補の最後に足す
            let kata = reading.applyingTransform(.hiraganaToKatakana, reverse: false) ?? reading
            if let half = kata.applyingTransform(.fullwidthToHalfwidth, reverse: false), half != kata, !have.contains(half) {
                extraAt = 10_000
                extras = [half]
            }
        }
        // 前に選んだ記号・数字の形・顔文字が、いちばん新しい記憶なら、帯の先頭に出す
        if extrasRememberable, !extras.isEmpty {
            let key = reading.applyingTransform(.hiraganaToKatakana, reverse: false) ?? reading
            if let first = chosen[key]?.first, let k = extras.firstIndex(of: first) {
                extras.remove(at: k)
                extras.insert(first, at: 0)
                extraAt = 0
            }
        }
    }
}
