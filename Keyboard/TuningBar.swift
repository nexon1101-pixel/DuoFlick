import SwiftUI

struct TuningParam: Identifiable {
    let id: String
    let label: String
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let keyPath: WritableKeyPath<KeyboardSettings, Double>
    let shapes: [KeyboardShape]
    /// 比べて決めるときの、最初のAとBの差の半分
    let compareDelta: Double?
}

enum TuningParams {
    static let all: [TuningParam] = [
        TuningParam(id: "w", label: "キーの幅", range: 6...16, step: 0.1, unit: "mm",
                    keyPath: \.keyWidthMM, shapes: [.rightGrid, .fan], compareDelta: 1.5),
        TuningParam(id: "h", label: "キーの高さ", range: 6...16, step: 0.1, unit: "mm",
                    keyPath: \.keyHeightMM, shapes: KeyboardShape.allCases, compareDelta: 1.5),
        TuningParam(id: "r", label: "カーブの半径", range: 25...200, step: 1, unit: "mm",
                    keyPath: \.fanRadiusMM, shapes: [.fan], compareDelta: 30),
        TuningParam(id: "a", label: "扇の向き", range: 60...150, step: 1, unit: "°",
                    keyPath: \.fanAngleDeg, shapes: [.fan], compareDelta: 10),
        TuningParam(id: "m", label: "端の余白", range: 0...20, step: 0.5, unit: "mm",
                    keyPath: \.marginMM, shapes: KeyboardShape.allCases, compareDelta: 3),
        TuningParam(id: "b", label: "下の余白", range: 0...20, step: 0.5, unit: "mm",
                    keyPath: \.bottomMarginMM, shapes: KeyboardShape.allCases, compareDelta: 3),
        TuningParam(id: "f", label: "フリック距離", range: 1.5...8, step: 0.1, unit: "mm",
                    keyPath: \.flickMinMM, shapes: KeyboardShape.allCases, compareDelta: 1.5),
        TuningParam(id: "g", label: "キーの間隔", range: 0...3, step: 0.1, unit: "mm",
                    keyPath: \.gapMM, shapes: KeyboardShape.allCases, compareDelta: nil),
        TuningParam(id: "e", label: "遠いキーの拡大", range: 0...50, step: 1, unit: "%",
                    keyPath: \.edgeGrowPercent, shapes: [.rightGrid, .fan], compareDelta: nil),
        TuningParam(id: "t", label: "方向の傾き", range: -30...30, step: 1, unit: "°",
                    keyPath: \.tiltDeg, shapes: KeyboardShape.allCases, compareDelta: nil),
    ]

    static func clamp(_ p: TuningParam, _ v: Double) -> Double {
        let c = min(p.range.upperBound, max(p.range.lowerBound, v))
        return (c / p.step).rounded() * p.step
    }

    static func format(_ p: TuningParam, _ v: Double) -> String {
        let number = p.step < 1 ? String(format: "%.1f", v) : String(format: "%.0f", v)
        return number + p.unit
    }
}

/// AとBを打ち比べて、選んだほうへ少しずつ近づけていく
struct CompareState {
    static let rounds = 4
    var params: [TuningParam]
    var index = 0
    var center: Double = 0
    var delta: Double = 0
    var round = 1
    var showingB = false
    var finished = false

    var param: TuningParam? { index < params.count ? params[index] : nil }
    var a: Double { param.map { TuningParams.clamp($0, center - delta) } ?? 0 }
    var b: Double { param.map { TuningParams.clamp($0, center + delta) } ?? 0 }
}

/// キーボードの上に出す調整バー。数値を変えるとすぐ下のキーボードに反映される。
struct TuningBar: View {
    @ObservedObject var model: SettingsModel
    let onClose: () -> Void
    @State private var selectedID = "w"
    @State private var compare: CompareState?

    private var params: [TuningParam] {
        TuningParams.all.filter { $0.shapes.contains(model.settings.shape) }
    }
    private var current: TuningParam? {
        params.first { $0.id == selectedID } ?? params.first
    }

    var body: some View {
        Group {
            if compare != nil {
                compareView
            } else {
                manualView
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 数値を直接変える

    private var manualView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Picker("形", selection: $model.settings.shape) {
                    Text("標準").tag(KeyboardShape.standard)
                    Text("右寄せ").tag(KeyboardShape.rightGrid)
                    Text("扇形").tag(KeyboardShape.fan)
                }
                .pickerStyle(.segmented)
                Button("閉じる", action: onClose)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("比べて決める", on: false, accent: true) { startCompare() }
                    if model.settings.shape == .fan {
                        chip(model.settings.followFan ? "扇に沿わせる：オン" : "扇に沿わせる：オフ",
                             on: model.settings.followFan) {
                            model.settings.followFan.toggle()
                        }
                    }
                    ForEach(params) { p in
                        chip(p.label, on: p.id == current?.id) { selectedID = p.id }
                    }
                    chip("初期値に戻す", on: false) {
                        model.settings = KeyboardSettings(shape: model.settings.shape)
                    }
                }
            }
            if let p = current {
                HStack(spacing: 8) {
                    Button { nudge(p, -p.step) } label: {
                        Image(systemName: "minus.circle.fill").font(.title3)
                    }
                    Slider(value: binding(p), in: p.range, step: p.step)
                    Button { nudge(p, p.step) } label: {
                        Image(systemName: "plus.circle.fill").font(.title3)
                    }
                    Text(TuningParams.format(p, model.settings[keyPath: p.keyPath]))
                        .font(.footnote.monospacedDigit())
                        .frame(width: 60, alignment: .trailing)
                }
            }
        }
    }

    private func chip(_ title: String, on: Bool, accent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(accent ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(on ? Color.accentColor : Color(uiColor: .secondarySystemBackground)))
                .overlay(Capsule().stroke(accent ? Color.accentColor : Color.clear, lineWidth: 1))
                .foregroundStyle(on ? Color.white : (accent ? Color.accentColor : Color.primary))
        }
        .buttonStyle(.plain)
    }

    private func binding(_ p: TuningParam) -> Binding<Double> {
        Binding(
            get: { model.settings[keyPath: p.keyPath] },
            set: { model.settings[keyPath: p.keyPath] = $0 }
        )
    }

    private func nudge(_ p: TuningParam, _ delta: Double) {
        model.settings[keyPath: p.keyPath] = TuningParams.clamp(p, model.settings[keyPath: p.keyPath] + delta)
    }

    // MARK: - 比べて決める

    @ViewBuilder
    private var compareView: some View {
        if let c = compare, let p = c.param, !c.finished {
            VStack(spacing: 8) {
                HStack {
                    Text("\(p.label)（\(c.index + 1)/\(c.params.count)項目・\(c.round)/\(CompareState.rounds)回目）")
                        .font(.footnote.weight(.semibold))
                    Spacer()
                    Button("この項目を飛ばす") { nextParam() }
                        .font(.footnote)
                    Button("終える") {
                        if let p = c.param { model.settings[keyPath: p.keyPath] = c.center }
                        compare = nil
                    }
                        .font(.footnote)
                }
                Picker("打ち比べ", selection: Binding(
                    get: { c.showingB },
                    set: { show($0) })) {
                    Text("A：\(TuningParams.format(p, c.a))").tag(false)
                    Text("B：\(TuningParams.format(p, c.b))").tag(true)
                }
                .pickerStyle(.segmented)
                HStack(spacing: 8) {
                    Button("Aがいい") { choose(c.a) }
                        .buttonStyle(.borderedProminent)
                    Button("同じくらい") { choose(c.center) }
                        .buttonStyle(.bordered)
                    Button("Bがいい") { choose(c.b) }
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
                Text("AとBを切り替えながら、下のキーボードで打ってみてください")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 10) {
                Text("比べて決める作業が終わりました。今の設定が保存されています。")
                    .font(.footnote)
                HStack {
                    Button("もう一度") { startCompare() }
                        .buttonStyle(.bordered)
                    Button("戻る") { compare = nil }
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
        }
    }

    private func startCompare() {
        let list = params.filter { $0.compareDelta != nil }
        compare = CompareState(params: list)
        beginParam()
    }

    private func beginParam() {
        guard var c = compare else { return }
        guard let p = c.param, let d = p.compareDelta else {
            c.finished = true
            compare = c
            return
        }
        c.center = model.settings[keyPath: p.keyPath]
        c.delta = d
        c.round = 1
        c.showingB = false
        compare = c
        apply()
    }

    private func show(_ b: Bool) {
        compare?.showingB = b
        apply()
    }

    private func apply() {
        guard let c = compare, let p = c.param else { return }
        model.settings[keyPath: p.keyPath] = c.showingB ? c.b : c.a
    }

    private func choose(_ value: Double) {
        guard var c = compare, let p = c.param else { return }
        c.center = value
        c.delta = max(p.step, c.delta / 2)
        c.round += 1
        compare = c
        if c.round > CompareState.rounds {
            model.settings[keyPath: p.keyPath] = value
            nextParam()
        } else {
            show(false)
        }
    }

    private func nextParam() {
        guard var c = compare else { return }
        if let p = c.param {
            // 飛ばしたときも、それまでに選んだ値（最初は元の値）に戻す
            model.settings[keyPath: p.keyPath] = c.center
        }
        c.index += 1
        compare = c
        beginParam()
    }
}
