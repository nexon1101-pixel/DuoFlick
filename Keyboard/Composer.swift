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

    /// 変換のときの設定
    private func requestOptionsForConvert() -> ConvertRequestOptions {
        options
    }

    /// 範囲選択中の、範囲の読み（範囲選択でないときは nil）
    var readingLabel: String? {
        if rangeMode, !composing.isEmpty { return rangeReading }
        return nil
    }

    /// 範囲選択中に、入力欄の下線の文字の中で選択して見せる範囲
    var markedHighlight: NSRange? {
        guard rangeMode else { return nil }
        // 範囲選択：先頭から範囲ぶんを選択状態に見せる（アプリが描く場合の補助）
        return NSRange(location: 0, length: (rangeShownPrefix as NSString).length)
    }

    /// 帯の番号（変換エンジンの候補の番号から、入れた候補の分だけずれる）
    private func displayIndex(forCandidate ci: Int) -> Int {
        let p = min(extraAt, candidates.count)
        return ci < p || extras.isEmpty ? ci : ci + extras.count
    }

    /// 入力欄に下線付きで表示する文字
    var markedText: String {
        if rangeMode {
            // 範囲だけを読みのまま（＝変換中）で見せ、後ろは仮で変換した形にする。
            // 選択範囲の描画はアプリ次第で当てにならないので、文字そのもので対象を示す
            return rangeShownPrefix + rangeRemainderText
        }
        if let i = selectedIndex, i < displayCount {
            if let ci = candidateIndex(forDisplay: i) {
                return candidates[ci].text + readingAfterSegment
            }
            return extraText(forDisplay: i) ?? composing.convertTarget
        }
        return composing.convertTarget
    }

    var candidateTexts: [String] {
        if rangeMode { return rangeCandidates.map(\.text) }
        return withExtra(candidates.map(\.text))
    }
    /// 一覧に出す候補（多すぎると重いので200個まで）
    var listTexts: [String] {
        if rangeMode { return rangeCandidates.map(\.text) }
        return withExtra(candidates.prefix(200).map(\.text))
    }

    // MARK: - 英字の候補（ローマ字かな入力で、打った英字のまま入れたいとき）

    /// 打った英字そのまま。ローマ字だけで打ち、読みを区切っていないときだけ出す
    private var rawRoman = ""
    /// 読みの1文字ごとの、打ち間違いかもしれない代わりの文字（タッチの位置と方向から。読みの長さと合うときだけ使う）
    private var altStack: [[String]] = []

    // MARK: - 打ち間違いの候補（「これかな？」）

    /// 濁点・半濁点・小書きの付け外しで変わる文字
    private static let kanaVariants: [Character: [Character]] = {
        var m: [Character: [Character]] = [:]
        func pair(_ a: String, _ b: String) {
            for (x, y) in zip(a, b) { m[x, default: []].append(y); m[y, default: []].append(x) }
        }
        pair("かきくけこさしすせそたちつてとはひふへほ", "がぎぐげござじずぜぞだぢづでどばびぶべぼ")
        pair("はひふへほ", "ぱぴぷぺぽ")
        pair("つやゆよあいうえおわ", "っゃゅょぁぃぅぇぉゎ")
        return m
    }()

    /// 点数の差（代わりの読み − 元の読み）がこれ以上なら、候補に出す。タッチの記録が裏づけるときは低くする（実機の値を見て調整する）
    static let typoMarginTouch: Float = 4
    static let typoMarginKana: Float = 8
    /// 元の読みに、ふつうの全体候補がないときの点数
    static let typoBaseless: Float = -35

    struct TypoHit {
        let candidate: Candidate
        let reading: String
        let diff: Float
        let touch: Bool
        let base: Float
    }

    /// 優先度を落とす形かどうか（消しはせず最後尾へ回す。本人が不要と言ったもの、2026-11-25）：
    /// ・濁点・半濁点が結合文字（または単独の゛゜）として付いた形（ヲ゚、ぇ゚、を゛ など）
    /// ・ワ・ヰ・ヱ・ヲに濁点の付いた合成済みの文字（ヷ・ヸ・ヹ・ヺ）。ゔ・ヴ は今どきの
    ///   書き方でも使うので残す
    /// ・株式会社系の形（（株）〇〇、〇〇（株）、株式会社〇〇、〇〇株式会社、㈱）。
    ///   括弧は半角で出てくる候補もあるので、判定の前に全角へ寄せる（花王(株)が実例）
    /// ・ギリシャ文字・キリル文字を含む候補と、記号だけでできた候補（くさい→Ξ・ξ、
    ///   きごう→記号の山。2026-11-25 の報告）。記号は記号の面から打てるので変換には出さない
    static func isUnwantedCandidate(_ text: String) -> Bool {
        let parens = text.replacingOccurrences(of: "(", with: "（").replacingOccurrences(of: ")", with: "）")
        if parens.contains("（株）") || text.contains("㈱") || text.contains("株式会社") { return true }
        if text.unicodeScalars.contains(where: {
            [0x3099, 0x309A, 0x309B, 0x309C, 0x30F7, 0x30F8, 0x30F9, 0x30FA].contains($0.value)
                || (0x0370...0x03FF).contains($0.value) || (0x0400...0x04FF).contains($0.value)
        }) { return true }
        // かな・漢字・英数字が1文字もない候補は、記号だけの候補として外す
        let hasUsable = text.unicodeScalars.contains { s in
            (0x3040...0x30FF).contains(s.value) || (0x3400...0x9FFF).contains(s.value)
                || (0xFF10...0xFF19).contains(s.value) || (0xFF21...0xFF3A).contains(s.value)
                || (0xFF41...0xFF5A).contains(s.value) || (0xFF66...0xFF9D).contains(s.value)
                || (0x30...0x39).contains(s.value) || (0x41...0x5A).contains(s.value)
                || (0x61...0x7A).contains(s.value) || s.value == 0x3005 || s.value == 0x3007
        }
        return !text.isEmpty && !hasUsable
    }

    /// 読み全体を覆う候補のうち、読みそのまま（ひらがな・カタカナ）でない最初のもの（AIなし、辞書だけで速く引く）
    private func bestExact(_ reading: String) -> Candidate? {
        // 前回の変換のラティスを使い回させない。文節・範囲の確定直後のラティスは、
        // ライブラリ側で prevs と values の数がずれたノードを含むことがあり、
        // 同じ読みの再リクエスト（キャッシュ復元）で落ちる（2026-11-22 のクラッシュ）。
        // 打ち間違い探しは毎回まっさらから計算させる
        converter.stopComposition()
        var ct = ComposingText()
        ct.insertAtCursorPosition(reading, inputStyle: .direct)
        var o = options
        o.needTypoCorrection = false
        let list = converter.requestCandidates(ct, options: o).mainResults
        let n = reading.count
        let kata = reading.applyingTransform(.hiraganaToKatakana, reverse: false) ?? reading
        let usable: (Candidate) -> Bool = { $0.rubyCount == n && !$0.data.isEmpty && $0.text != reading && $0.text != kata }
        return list.first { usable($0) && !Self.isUnwantedCandidate($0.text) } ?? list.first { usable($0) }
    }

    /// 1文字だけ打ち間違えたとして、代わりの読みを変換し、元の読みより点数が上がるものを返す（all が true なら、しきい値に関係なく全部）
    func typoScan(_ reading: String, touch: [[String]], all: Bool = false) -> [TypoHit] {
        let chars = Array(reading)
        let n = chars.count
        guard converterReady, n >= 2, n <= 14, Self.isHiragana(reading) else { return [] }
        var variants: [(reading: String, touch: Bool)] = []
        var seen = Set([reading])
        func add(_ i: Int, _ c: Character, _ byTouch: Bool) {
            guard Self.isHiragana(String(c)) else { return }
            var v = chars
            v[i] = c
            let r = String(v)
            if seen.insert(r).inserted { variants.append((r, byTouch)) }
        }
        if touch.count == n {
            for i in max(0, n - 6)..<n {
                for a in touch[i] { if a.count == 1, let c = a.first { add(i, c, true) } }
            }
        }
        for i in max(0, n - 2)..<n {
            for c in Self.kanaVariants[chars[i]] ?? [] { add(i, c, false) }
        }
        guard !variants.isEmpty else { return [] }
        let base = bestExact(reading).map { Float($0.value) } ?? Self.typoBaseless
        var hits: [TypoHit] = []
        for v in variants.prefix(8) {
            guard let c = bestExact(v.reading) else { continue }
            let d = Float(c.value) - base
            if all || d >= (v.touch ? Self.typoMarginTouch : Self.typoMarginKana) {
                hits.append(TypoHit(candidate: c, reading: v.reading, diff: d, touch: v.touch, base: base))
            }
        }
        converter.stopComposition()
        return hits.sorted { $0.diff > $1.diff }
    }
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

    private var displayCount: Int {
        if rangeMode { return rangeCandidates.count }
        return candidates.count + extras.count
    }

    /// 帯の番号から変換候補の番号を求める（入れた候補なら nil）
    private func candidateIndex(forDisplay i: Int) -> Int? {
        guard !extras.isEmpty else { return i }
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
        "、": ["，", ",", "､", "・", "…"], "。": ["…", "．", ".", "｡", "‥", "・"],
        "？": ["?", "⁇"], "！": ["!", "‼", "❗"],
        "「": ["『", "｢", "（", "【", "［", "〈", "《"], "」": ["』", "｣", "）", "】", "］", "〉", "》"],
        "ー": ["〜", "～", "—", "―", "-", "－"], "・": ["･", "…", "/", "／"],
        "〜": ["～", "ー", "—"], "…": ["‥", "・・・"],
    ]

    /// 記号が続いたときの候補（読みがそのまま合うとき）。「。。。」→「…」など
    private static let punctuationRuns: [String: [String]] = [
        "。。": ["‥", "…"], "。。。": ["…", "‥", "……"], "、、、": ["…", "・・・"], "・・・": ["…", "‥", "……"],
        "！！": ["‼", "!!", "！！！"], "？？": ["⁇", "??", "？？？"], "！？": ["⁉", "!?"], "？！": ["⁈", "?!"],
        "ーー": ["——", "――", "〜〜"], "ーーー": ["——", "――", "〜〜〜"],
        "〜〜": ["～～", "〜〜〜"],
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
    func insert(_ s: String, roman: Bool = false, alts: [String] = []) {
        // 範囲選択の途中で打ち足したら、範囲選択は終えて通常の入力に戻る
        if rangeMode { exitRangeMode() }
        clearPredictions()
        selectedIndex = nil
        // 入力が空から始まるときは、前に打った英字の記録を捨てる（確定や全削除のあとに残っていた）
        if composing.isEmpty { rawRoman = ""; rawValid = true }
        // 文節を区切っていた場合も、入力は末尾に足す
        _ = composing.moveCursorFromCursorPosition(count: composing.convertTarget.count)
        let before = composing.convertTarget.count
        composing.insertAtCursorPosition(s, inputStyle: roman ? .roman2kana : .direct)
        // 打ち間違いの代わりの文字を、読みの1文字ごとに覚える（読みの長さと合わなくなったら捨てる）
        let added = composing.convertTarget.count - before
        if altStack.count == before, added >= 1 {
            altStack.append(contentsOf: (0..<added).map { $0 == added - 1 ? alts : [] })
        } else {
            altStack = Array(repeating: [], count: composing.convertTarget.count)
        }
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
        if !altStack.isEmpty { altStack[altStack.count - 1] = [] }
        rawValid = false
        markDirty()
        return true
    }

    func deleteBackward() {
        if rangeMode {
            // 範囲選択の途中なら、まず範囲選択を終える（文節の選び直しと同じ）
            exitRangeMode()
            return
        }
        if selectedIndex != nil {
            // 候補を選んでいる途中なら、選択を解除してひらがなに戻す
            selectedIndex = nil
            return
        }
        _ = composing.moveCursorFromCursorPosition(count: composing.convertTarget.count)
        composing.deleteBackwardFromCursorPosition(count: 1)
        while altStack.count > composing.convertTarget.count { altStack.removeLast() }
        syncRaw()
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
        guard displayCount > 0 else { return }
        if let i = selectedIndex {
            selectedIndex = (i + 1) % displayCount
        } else {
            selectedIndex = 0
        }
    }

    /// 候補を確定する。確定した文字を返す。
    func commit(candidateAt index: Int) -> String? {
        if rangeMode { return commitRange(candidateAt: index) }
        guard index < displayCount else { return nil }
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

    // MARK: - 範囲選択（候補を長押しして、そのままドラッグで「前から何文字ぶん変換するか」を自分で決める）

    /// 範囲選択の状態か
    private(set) var rangeMode = false
    /// 前から何文字を範囲にするか
    private(set) var rangeLength = 0
    /// 範囲だけの候補
    private var rangeCandidates: [Candidate] = []
    /// 範囲の後ろの読みを、そのまま見せる形（変換はしない。v0.37.35〜）
    private var rangeRemainderText = ""

    /// 範囲の読み（先頭から rangeLength 文字）
    private var rangeReading: String { String(composing.convertTarget.prefix(rangeLength)) }

    /// 範囲の後ろの読み（範囲選択の外側）
    var rangeSuffixReading: String { String(composing.convertTarget.dropFirst(rangeLength)) }

    /// 範囲だけを変換中で見せるときの形（候補を選んでいればその候補、なければ範囲の読み）
    var rangeMarkedText: String { rangeShownPrefix }

    /// 範囲選択中に、入力欄の先頭に出す形（候補を選んでいればその候補、なければ範囲の読み）
    private var rangeShownPrefix: String {
        if let i = selectedIndex, i >= 0, i < rangeCandidates.count { return rangeCandidates[i].text }
        return rangeReading
    }

    /// 候補の長押しで範囲選択に入る。最初の範囲は読み全体で、先頭を固定したまま
    /// ドラッグ（前にスクロール）で末尾から狭めていく
    func enterRangeMode(candidateAt index: Int) -> Bool {
        // 範囲は「読み」に対して決めるもので、押した候補が変換候補そのものかは関係ない。
        // 先頭に読みそのまま等の追加候補が並ぶ場合に候補対応付けが取れず、入口で無言で失敗していた（v0.37.28）
        guard !composing.isEmpty, index < displayCount else { return false }
        rangeLength = composing.convertTarget.count
        rangeMode = true
        selectedIndex = nil
        loadRangeCandidates()
        return true
    }

    /// ドラッグで範囲の長さを変える。変わったら true
    @discardableResult
    func setRangeLength(_ n: Int) -> Bool {
        guard rangeMode else { return false }
        let clamped = min(max(n, 1), composing.convertTarget.count)
        guard clamped != rangeLength else { return false }
        rangeLength = clamped
        loadRangeCandidates()
        return true
    }

    /// 範囲選択をやめる（確定はしない）
    func exitRangeMode() {
        rangeMode = false
        rangeLength = 0
        rangeCandidates = []
        rangeRemainderText = ""
    }

    /// 範囲の読みだけを変換して、候補を集める（文節の候補を集めるのと同じやり方）
    private func loadRangeCandidates() {
        let reading = rangeReading
        var ct = ComposingText()
        ct.insertAtCursorPosition(reading, inputStyle: .direct)
        var o = options
        o.needTypoCorrection = false
        let n = reading.count
        var list: [Candidate] = []
        var demoted: [Candidate] = []
        var seen = Set<String>()
        for c in converter.requestCandidates(ct, options: o).mainResults
        where c.rubyCount == n && seen.insert(c.text).inserted {
            if Self.isUnwantedCandidate(c.text) { demoted.append(c) } else { list.append(c) }
            if list.count >= 40 { break }
        }
        for t in [reading, Self.katakana(reading)] where seen.insert(t).inserted {
            list.append(Candidate(text: t, value: -20, composingCount: .surfaceCount(n), lastMid: 501,
                                  data: [DicdataElement(word: t, ruby: Self.katakana(reading),
                                                        cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -20)]))
        }
        list.append(contentsOf: demoted.prefix(40))
        rangeCandidates = list
        selectedIndex = nil
        // 範囲の後ろは変換せず、読みのまま見せる（「勝手に変換される」と感じさせないため。v0.37.35）
        rangeRemainderText = String(composing.convertTarget.dropFirst(rangeLength))
    }

    /// 範囲選択で候補を選ぶ：範囲だけを確定し、残りの読みは変換待ちのまま残す
    func commitRange(candidateAt index: Int) -> String? {
        guard rangeMode, index >= 0, index < rangeCandidates.count else { return nil }
        let c = rangeCandidates[index]
        exitRangeMode()
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
        // 候補を選んでいない確定は、読みのままにする。前によく選んだ記号の形が帯の先頭に
        // あっても、勝手にそれで確定しない（「。」を打って確定したら「…」が出た、という報告への対応）
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
        exitRangeMode()
        rawRoman = ""
        rawValid = true
        extras = []
        altStack = []
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

        var zt = ComposingText()
        zt.insertAtCursorPosition("かいとう", inputStyle: .direct)
        let off = converter.requestCandidates(zt, options: options).mainResults.prefix(5).map(\.text)
        converter.stopComposition()
        lines.append("かいとう：\(off.joined(separator: " / "))")

        // 途中の読みの判定用：候補ごとの点数（value）と長さ。「全」＝読み全体を覆う候補、「予」＝読みの続きを補った予測
        lines.append("――候補の点数――")
        for r in ["こんにち", "こんにちは", "かいとう", "とうきょ", "わたしの", "ありがと", "こうりょして", "して", "どうして", "してって"] {
            var ct = ComposingText()
            ct.insertAtCursorPosition(r, inputStyle: .direct)
            let list = converter.requestCandidates(ct, options: options).mainResults.prefix(7)
            converter.stopComposition()
            let s = list.map { c in
                "\(c.rubyCount == r.count ? "全" : (c.rubyCount > r.count ? "予" : "短"))\(c.text)(\(String(format: "%.1f", Float(c.value))))"
            }
            lines.append("\(r)：\(s.joined(separator: " "))")
        }
        lines.append("――打ち間違いの候補（代わりの読み：点数の差）――")
        for r in ["こんにちわ", "ありかとう", "おはよお", "てんき", "ありがとう", "きがする"] {
            let hs = typoScan(r, touch: [], all: true)
            if hs.isEmpty { lines.append("\(r)：代わりなし"); continue }
            lines.append("\(r)（元 \(String(format: "%.1f", hs[0].base))）：" + hs.prefix(5).map {
                "\($0.reading)=\($0.candidate.text)(\(String(format: "%+.1f", $0.diff)))"
            }.joined(separator: " "))
        }
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
        return front + rest
    }

    /// 変換候補が今の読みに追いついていないか
    private(set) var needsRefresh = false
    /// 打ち間違いを直した候補も出すか（設定で切り替える）
    var typoCorrection = false

    /// 読みが変わったら、後でまとめて変換する（打鍵のたびに変換すると重いため）。
    /// 変換が終わるまでは前の候補を出したままにして、帯がちらつかないようにする。
    private func markDirty() {
        needsRefresh = true
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
            if converterReady { converter.stopComposition() }
            return
        }
        let target = isSegmented ? composing.prefixToCursorPosition() : composing
        var requestOptions = requestOptionsForConvert()
        requestOptions.needTypoCorrection = typoCorrection
        var found = converter.requestCandidates(target, options: requestOptions).mainResults
        // 絵文字の候補は出さない（顔文字は、読みから足す処理をやめた）
        found = found.filter { c in !c.text.unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000) } }
        // 要らない候補（ヲ゚・（株）・記号だけ等）は消さず、優先度を落として最後尾へ回す（本人の指示、2026-11-25）
        var demoted: [Candidate] = []
        found = found.filter { c in
            if Self.isUnwantedCandidate(c.text) { demoted.append(c); return false }
            return true
        }
        candidates = prioritizeChosen(found) + demoted
        // 打ち間違いの候補（「これかな？」）：代わりの読みで点数が大きく上がるものを、3番目に足す
        if typoCorrection, !isSegmented, converterReady {
            let r = composing.convertTarget
            let hits = typoScan(r, touch: altStack.count == r.count ? altStack : [])
            let have = Set(candidates.map(\.text))
            let add = hits.prefix(2).map(\.candidate).filter { !have.contains($0.text) }
            if !add.isEmpty { candidates.insert(contentsOf: add, at: min(2, candidates.count)) }
        }
        extras = []
        guard !isSegmented else { return }
        let reading = composing.convertTarget
        let have = Set(candidates.map(\.text))
        extrasRememberable = false
        if reading == "きょう" || reading == "いま" {
            // 今日の日付と今の時刻（変換エンジンの候補にない形だけ足す）
            extraAt = 1
            for v in Self.dateTimeCandidates(for: reading) where !have.contains(v) { extras.append(v) }
        } else if reading == "きのう" {
            // 「昨日」が同梱辞書の「きのう」に無く、漢字に変換できなかった（2026-11-25 の報告）
            extraAt = 1
            for v in ["昨日"] where !have.contains(v) { extras.append(v) }
        } else if let list = Self.punctuationRuns[reading] {
            extraAt = 1
            extrasRememberable = true
            for v in list where !have.contains(v) { extras.append(v) }
        } else if reading.count == 1, let c = reading.first, let list = Self.punctuationVariants[c] {
            extraAt = 1
            extrasRememberable = true
            for v in list where !have.contains(v) { extras.append(v) }
        } else if !reading.prefix(while: { $0.isASCII && $0.isNumber }).isEmpty,
                  !reading.drop(while: { $0.isASCII && $0.isNumber }).isEmpty,
                  reading.drop(while: { $0.isASCII && $0.isNumber }).allSatisfy({ "、。？！,.?!".contains($0) }) {
            // 数字＋末尾の記号（例：100、）：記号が付くと数字だけの候補が出なくなり、漢数字に
            // 変換できなかった。数字部分の候補に記号を付けた形を出す（v0.37.48）
            let digits = String(reading.prefix(while: { $0.isASCII && $0.isNumber }))
            let punct = String(reading.drop(while: { $0.isASCII && $0.isNumber }))
            extraAt = 1
            extrasRememberable = true
            for v in Self.numberVariants(digits) where !have.contains(v + punct) && !extras.contains(v + punct) { extras.append(v + punct) }
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
