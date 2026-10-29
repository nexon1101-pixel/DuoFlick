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
        TuningParam(id: "l", label: "文字の大きさ", range: 0.7...1.4, step: 0.05, unit: "倍",
                    keyPath: \.labelScale, shapes: KeyboardShape.allCases, compareDelta: nil),
    ]

    static func clamp(_ p: TuningParam, _ v: Double) -> Double {
        let c = min(p.range.upperBound, max(p.range.lowerBound, v))
        return (c / p.step).rounded() * p.step
    }

    static func format(_ p: TuningParam, _ v: Double) -> String {
        let number = p.step < 0.1 ? String(format: "%.2f", v) : (p.step < 1 ? String(format: "%.1f", v) : String(format: "%.0f", v))
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
    @ObservedObject var dictionary: UserDictionaryStore
    let onClose: () -> Void
    let onRegister: () -> Void
    let diagnose: () -> String
    let onPhrases: () -> Void
    let onClipboard: () -> Void
    let offsetText: () -> String
    let onResetOffset: () -> Void
    let onOptimize: () -> Void
    @State private var diagnosis: String?
    @State private var showThemes = false
    @State private var showPresets = false
    @State private var selectedID = "w"
    @State private var compare: CompareState?
    @State private var showDictionary = false

    private var params: [TuningParam] {
        TuningParams.all.filter { $0.shapes.contains(model.settings.shape) }
    }
    private var current: TuningParam? {
        params.first { $0.id == selectedID } ?? params.first
    }

    var body: some View {
        Group {
            if let d = diagnosis {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("変換の診断").font(.footnote.weight(.semibold))
                        Spacer()
                        Button("戻る") { diagnosis = nil }.font(.footnote)
                    }
                    ScrollView {
                        Text(d).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if showThemes {
                themeView
            } else if showPresets {
                presetView
            } else if showDictionary {
                dictionaryView
            } else if compare != nil {
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
                Text(model.profile.title).font(.caption2).foregroundStyle(.secondary)
                Picker("形", selection: $model.settings.shape) {
                    Text("両手").tag(KeyboardShape.standard)
                    Text("片手・格子").tag(KeyboardShape.rightGrid)
                    Text("片手・扇形").tag(KeyboardShape.fan)
                }
                .pickerStyle(.segmented)
                Button("閉じる", action: onClose)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("打ち比べで最適化", on: false, accent: true) { onOptimize() }
                    if model.settings.shape != .standard {
                        chip(model.settings.hand == .right ? "片手：右手" : "片手：左手", on: true) {
                            model.settings.hand = model.settings.hand == .right ? .left : .right
                        }
                    }
                    chip("定型文", on: false) { onPhrases() }
                    chip("クリップボード", on: false) { onClipboard() }
                    chip("単語登録", on: false) { onRegister() }
                    chip("辞書の一覧", on: false) { showDictionary = true }
                    chip("配色", on: false) { showThemes = true }
                    chip("保存と呼び出し", on: false) { showPresets = true }
                    chip(model.settings.haptics ? "振動：オン" : "振動：オフ", on: model.settings.haptics) {
                        model.settings.haptics.toggle()
                    }
                    chip(model.settings.autoCorrect ? "ずれ補正：オン" : "ずれ補正：オフ", on: model.settings.autoCorrect) {
                        model.settings.autoCorrect.toggle()
                    }
                    chip("ずれ補正をリセット（\(offsetText())）", on: false) { onResetOffset() }
                    chip("変換の診断", on: false) { diagnosis = diagnose() }
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

    // MARK: - 配色

    private var themeView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("配色").font(.footnote.weight(.semibold))
                Spacer()
                Button("戻る") { showThemes = false }.font(.footnote)
            }
            themeRow("ライト", selection: $model.settings.themeLight)
            themeRow("ダーク", selection: $model.settings.themeDark)
        }
    }

    private func themeRow(_ title: String, selection: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).frame(width: 40, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(KeyTheme.all, id: \.id) { t in
                        chip(t.name, on: selection.wrappedValue == t.id) { selection.wrappedValue = t.id }
                    }
                }
            }
        }
    }

    // MARK: - 設定の保存と呼び出し

    private var presetView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("設定の保存と呼び出し").font(.footnote.weight(.semibold))
                Spacer()
                Button("今の設定を保存") { model.savePreset() }.font(.footnote)
                Button("戻る") { showPresets = false }.font(.footnote)
            }
            if model.presets.isEmpty {
                Text("保存した設定はまだありません。5つまで保存できます。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.presets) { p in
                            HStack {
                                Text(p.name).font(.footnote)
                                Text(shapeName(p.settings)).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("呼び出す") { model.loadPreset(p) }.font(.footnote)
                                Button(role: .destructive) { model.deletePreset(p) } label: {
                                    Image(systemName: "trash")
                                }
                                .font(.footnote)
                            }
                        }
                    }
                }
            }
        }
    }

    private func shapeName(_ s: KeyboardSettings) -> String {
        switch s.shape {
        case .standard: return "両手"
        case .rightGrid: return s.hand == .right ? "片手・格子・右手" : "片手・格子・左手"
        case .fan: return s.hand == .right ? "片手・扇形・右手" : "片手・扇形・左手"
        }
    }

    // MARK: - ユーザー辞書

    private var dictionaryView: some View {
        VStack(spacing: 6) {
            HStack {
                Text("ユーザー辞書（\(dictionary.words.count)語）").font(.footnote.weight(.semibold))
                Spacer()
                Button("戻る") { showDictionary = false }.font(.footnote)
            }
            if dictionary.words.isEmpty {
                Text("登録した単語はまだありません。「単語登録」から追加できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(dictionary.words) { w in
                            HStack {
                                Text(w.word).font(.footnote)
                                Text(w.reading).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button(role: .destructive) { dictionary.remove(w) } label: {
                                    Image(systemName: "trash")
                                }
                                .font(.footnote)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
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
