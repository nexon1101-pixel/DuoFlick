import SwiftUI
import Combine

/// 打ち比べで設定を詰める。A と B で同じお題を打ってもらい、時間とミスを比べて選んでもらう。
final class OptimizerModel: ObservableObject {
    enum Phase { case typingA, typingB, choose, finished }

    struct Item {
        let id: String
        let label: String
        let keyPath: WritableKeyPath<KeyboardSettings, Double>
        let range: ClosedRange<Double>
        let step: Double
        let unit: String
        let delta: Double
        let shapes: [KeyboardShape]
    }

    struct Score {
        var time: Double = 0
        var misses: Int = 0
        var value: Double { time * (1 + 0.3 * Double(misses)) }
    }

    static let roundsPerItem = 3

    static let allItems: [Item] = [
        Item(id: "w", label: "キーの幅", keyPath: \.keyWidthMM, range: 6...16, step: 0.1, unit: "mm", delta: 1.2, shapes: [.rightGrid, .fan]),
        Item(id: "h", label: "キーの高さ", keyPath: \.keyHeightMM, range: 6...16, step: 0.1, unit: "mm", delta: 1.2, shapes: KeyboardShape.allCases),
        Item(id: "g", label: "キーの間隔", keyPath: \.gapMM, range: 0...3, step: 0.1, unit: "mm", delta: 0.6, shapes: KeyboardShape.allCases),
        Item(id: "r", label: "カーブの半径", keyPath: \.fanRadiusMM, range: 25...200, step: 1, unit: "mm", delta: 25, shapes: [.fan]),
        Item(id: "a", label: "扇の向き", keyPath: \.fanAngleDeg, range: 60...150, step: 1, unit: "°", delta: 8, shapes: [.fan]),
        Item(id: "e", label: "遠いキーの拡大", keyPath: \.edgeGrowPercent, range: 0...50, step: 1, unit: "%", delta: 10, shapes: [.rightGrid, .fan]),
        Item(id: "m", label: "端の余白", keyPath: \.marginMM, range: 0...20, step: 0.5, unit: "mm", delta: 2.5, shapes: KeyboardShape.allCases),
        Item(id: "b", label: "下の余白", keyPath: \.bottomMarginMM, range: 0...20, step: 0.5, unit: "mm", delta: 2.5, shapes: KeyboardShape.allCases),
        Item(id: "f", label: "フリック距離", keyPath: \.flickMinMM, range: 1.5...8, step: 0.1, unit: "mm", delta: 1.2, shapes: KeyboardShape.allCases),
        Item(id: "t", label: "フリック方向の傾き", keyPath: \.tiltDeg, range: -30...30, step: 1, unit: "°", delta: 8, shapes: KeyboardShape.allCases),
    ]

    /// お題に使う文字（全部のキー・全部の方向が出るように）
    private static let pool: [String] = {
        let rows = ["あいうえお", "かきくけこ", "さしすせそ", "たちつてと", "なにぬねの",
                    "はひふへほ", "まみむめも", "やゆよ", "らりるれろ", "わをん"]
        return rows.flatMap { $0.map { String($0) } }
    }()

    @Published private(set) var phase: Phase = .typingA
    @Published private(set) var items: [Item] = []
    @Published private(set) var index = 0
    @Published private(set) var round = 1
    @Published private(set) var center: Double = 0
    @Published private(set) var delta: Double = 0
    @Published private(set) var target: [String] = []
    @Published private(set) var typed = 0
    @Published private(set) var scoreA = Score()
    @Published private(set) var scoreB = Score()
    @Published private(set) var pass = 1

    private var startTime: Date?
    private weak var model: SettingsModel?

    var item: Item? { index < items.count ? items[index] : nil }
    var a: Double { item.map { clamp($0, center - delta) } ?? 0 }
    var b: Double { item.map { clamp($0, center + delta) } ?? 0 }

    /// 数字から見て、よさそうな側（"A" / "B" / nil）
    var suggestion: String? {
        let d = scoreA.value - scoreB.value
        if abs(d) < 0.15 * max(scoreA.value, scoreB.value) { return nil }
        return d < 0 ? "A" : "B"
    }

    func start(model: SettingsModel) {
        self.model = model
        items = Self.allItems.filter { $0.shapes.contains(model.settings.shape) }
        index = 0
        pass = 1
        beginItem()
    }

    /// 一巡したあと、さらに細かい差で続ける
    func continueFiner() {
        pass += 1
        index = 0
        beginItem()
    }

    func skipItem() {
        restoreCenter()
        index += 1
        beginItem()
    }

    func finish() {
        restoreCenter()
        phase = .finished
    }

    /// お題を打っている間のキー入力（入力欄には入れない）
    func input(_ s: String) {
        guard phase == .typingA || phase == .typingB, typed < target.count else { return }
        if startTime == nil { startTime = Date() }
        if s == target[typed] {
            typed += 1
            if typed == target.count { finishTyping() }
        } else {
            if phase == .typingA { scoreA.misses += 1 } else { scoreB.misses += 1 }
        }
    }

    /// お題を打ち直す
    func retype() {
        typed = 0
        startTime = nil
        if phase == .typingA { scoreA = Score() } else if phase == .typingB { scoreB = Score() }
    }

    func choose(_ side: String?) {
        guard let it = item else { return }
        switch side {
        case "A": center = a
        case "B": center = b
        default: break
        }
        delta = max(it.step, delta / 2)
        round += 1
        if round > Self.roundsPerItem {
            restoreCenter()
            index += 1
            beginItem()
        } else {
            beginRound()
        }
    }

    private func beginItem() {
        guard let it = item, let model else {
            phase = .finished
            return
        }
        center = model.settings[keyPath: it.keyPath]
        // 2巡目以降は差を小さくする
        delta = max(it.step, it.delta / pow(2, Double(pass - 1)))
        round = 1
        beginRound()
    }

    private func beginRound() {
        target = (0..<5).map { _ in Self.pool.randomElement() ?? "あ" }
        scoreA = Score()
        scoreB = Score()
        phase = .typingA
        typed = 0
        startTime = nil
        apply(a)
    }

    private func finishTyping() {
        let t = Date().timeIntervalSince(startTime ?? Date())
        if phase == .typingA {
            scoreA.time = t
            phase = .typingB
            typed = 0
            startTime = nil
            apply(b)
        } else {
            scoreB.time = t
            phase = .choose
            restoreCenter()
        }
    }

    private func apply(_ v: Double) {
        guard let it = item, let model else { return }
        model.settings[keyPath: it.keyPath] = v
    }

    private func restoreCenter() {
        guard let it = item, let model else { return }
        model.settings[keyPath: it.keyPath] = clamp(it, center)
    }

    private func clamp(_ it: Item, _ v: Double) -> Double {
        let c = min(it.range.upperBound, max(it.range.lowerBound, v))
        return (c / it.step).rounded() * it.step
    }

    func format(_ v: Double) -> String {
        guard let it = item else { return "" }
        let n = it.step < 1 ? String(format: "%.1f", v) : String(format: "%.0f", v)
        return n + it.unit
    }
}

/// 打ち比べの画面（キーボードの上に出す）
struct OptimizerPanel: View {
    @ObservedObject var opt: OptimizerModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            switch opt.phase {
            case .typingA, .typingB:
                typingView
            case .choose:
                chooseView
            case .finished:
                finishedView
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var header: some View {
        HStack {
            if let it = opt.item, opt.phase != .finished {
                Text("\(it.label)（\(opt.index + 1)/\(opt.items.count)・\(opt.round)/\(OptimizerModel.roundsPerItem)回目）")
                    .font(.footnote.weight(.semibold))
            } else {
                Text("打ち比べで最適化").font(.footnote.weight(.semibold))
            }
            Spacer()
            if opt.phase != .finished {
                Button("飛ばす") { opt.skipItem() }.font(.footnote)
            }
            Button("終える") {
                opt.finish()
                onClose()
            }
            .font(.footnote)
        }
    }

    private var typingView: some View {
        let side = opt.phase == .typingA ? "A" : "B"
        let value = opt.phase == .typingA ? opt.a : opt.b
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(side)（\(opt.format(value))）で、下のお題を打ってください")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                ForEach(Array(opt.target.enumerated()), id: \.offset) { i, ch in
                    Text(ch)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(i < opt.typed ? Color.green : (i == opt.typed ? Color.primary : Color.secondary))
                        .underline(i == opt.typed)
                }
                Spacer()
                Button("打ち直す") { opt.retype() }.font(.caption)
            }
        }
    }

    private var chooseView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                result("A", opt.a, opt.scoreA)
                result("B", opt.b, opt.scoreB)
            }
            HStack(spacing: 8) {
                choice("A")
                Button("同じくらい") { opt.choose(nil) }
                    .buttonStyle(.bordered)
                choice("B")
            }
            .controlSize(.small)
        }
    }

    private func result(_ side: String, _ v: Double, _ s: OptimizerModel.Score) -> some View {
        Text("\(side)（\(opt.format(v))）：\(String(format: "%.1f", s.time))秒・ミス\(s.misses)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(opt.suggestion == side ? Color.accentColor : Color.primary)
    }

    @ViewBuilder
    private func choice(_ side: String) -> some View {
        if opt.suggestion == side {
            Button("\(side)がいい") { opt.choose(side) }.buttonStyle(.borderedProminent)
        } else {
            Button("\(side)がいい") { opt.choose(side) }.buttonStyle(.bordered)
        }
    }

    private var finishedView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("一巡しました。今の設定が保存されています。さらに細かい差で詰めることもできます。")
                .font(.caption)
            HStack {
                Button("続ける（\(opt.pass + 1)巡目）") { opt.continueFiner() }
                    .buttonStyle(.borderedProminent)
                Button("閉じる", action: onClose)
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
    }
}
