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

/// 設定画面から呼ぶ操作
struct SettingsActions {
    let onClose: () -> Void
    let onAdjust: () -> Void
    let onOptimize: () -> Void
    let onRegister: () -> Void
    let onPhrases: () -> Void
    let onClipboard: () -> Void
    let diagnose: () -> String
    let offsetText: () -> String
    let onResetOffset: () -> Void
    /// iOSのユーザ辞書を取り込む。終わったら結果の文を渡す
    let importSystemDictionary: (@escaping (String) -> Void) -> Void
}

/// 地球儀キーの上フリックで開く設定画面。キーボードの場所いっぱいに一覧で出す。
struct SettingsScreen: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var dictionary: UserDictionaryStore
    let actions: SettingsActions

    private enum Page { case main, themes, presets, dictionary, diagnosis }
    @State private var page: Page = .main
    @State private var diagnosis = ""
    @State private var confirmReset = false
    @State private var offset = ""
    @State private var importMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch page {
            case .main: mainPage
            case .themes: themePage
            case .presets: presetPage
            case .dictionary: dictionaryPage
            case .diagnosis: diagnosisPage
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onAppear { offset = actions.offsetText() }
    }

    private var title: String {
        switch page {
        case .main: return "設定（\(model.title)）"
        case .themes: return "配色"
        case .presets: return "設定の保存と呼び出し"
        case .dictionary: return "ユーザー辞書（\(dictionary.words.count)語）"
        case .diagnosis: return "変換の診断"
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if page != .main {
                Button { page = .main } label: {
                    Label("戻る", systemImage: "chevron.left").font(.subheadline)
                }
            }
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer()
            Button("閉じる", action: actions.onClose)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    // MARK: - 一覧

    private var mainPage: some View {
        Form {
            Section {
                Picker("持ち方", selection: Binding(
                    get: { model.grip },
                    set: { if $0 != model.grip { model.toggleGrip() } })) {
                    Text("片手持ち").tag(Grip.one)
                    Text("両手持ち").tag(Grip.two)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("持ち方")
            } footer: {
                Text("片手持ちと両手持ちで、形や大きさを別々に覚えます。左下のキーでも切り替えられます。")
            }
            Section("形") {
                Picker("形", selection: $model.settings.shape) {
                    Text("両手").tag(KeyboardShape.standard)
                    Text("片手・格子").tag(KeyboardShape.rightGrid)
                    Text("片手・扇形").tag(KeyboardShape.fan)
                }
                .pickerStyle(.segmented)
                if model.settings.shape != .standard {
                    Picker("手", selection: $model.settings.hand) {
                        Text("右手").tag(Hand.right)
                        Text("左手").tag(Hand.left)
                    }
                    .pickerStyle(.segmented)
                }
                if model.settings.shape == .fan {
                    Toggle("文字を扇に沿わせる", isOn: $model.settings.followFan)
                }
            }
            Section {
                row("キーを見ながら調整", detail: "大きさ・余白など", action: actions.onAdjust)
                row("打ち比べで最適化", detail: nil, action: actions.onOptimize)
            } header: {
                Text("大きさと位置")
            }
            Section("入力") {
                Toggle("押したときの振動", isOn: $model.settings.haptics)
                Toggle("続けてタップで文字を切り替え", isOn: $model.settings.toggleTap)
                Toggle("ずれ補正（押す位置と斜めのくせ）", isOn: $model.settings.autoCorrect)
                Toggle("打ち間違いの候補（試験的）", isOn: $model.settings.typoCorrection)
                Toggle("AIで変換（試験的）", isOn: $model.settings.zenzai)
                Button {
                    actions.onResetOffset()
                    offset = actions.offsetText()
                } label: {
                    HStack {
                        Text("ずれ補正をリセット")
                        Spacer()
                        Text(offset).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Section("便利な機能") {
                row("定型文", detail: nil, action: actions.onPhrases)
                row("クリップボードの履歴", detail: nil, action: actions.onClipboard)
            }
            Section("辞書") {
                row("単語登録", detail: "選択した語を登録", action: actions.onRegister)
                row("辞書の一覧", detail: "\(dictionary.words.count)語") { page = .dictionary }
                Button {
                    importMessage = "読み込み中…"
                    actions.importSystemDictionary { importMessage = $0 }
                } label: {
                    HStack {
                        Text("iOSのユーザ辞書を取り込む")
                        Spacer()
                        Text(importMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Section("見た目") {
                row("配色", detail: themeName) { page = .themes }
            }
            Section("その他") {
                row("設定の保存と呼び出し", detail: "\(model.presets.count)件") { page = .presets }
                row("変換の診断", detail: nil) {
                    diagnosis = actions.diagnose()
                    page = .diagnosis
                }
                Button(role: .destructive) {
                    if confirmReset {
                        model.settings = KeyboardSettings(shape: model.settings.shape)
                        confirmReset = false
                    } else {
                        confirmReset = true
                    }
                } label: {
                    Text(confirmReset ? "もう一度押すと初期値に戻します" : "形と大きさを初期値に戻す")
                }
            }
        }
        .environment(\.defaultMinListRowHeight, 40)
        .listSectionSpacing(.compact)
    }

    private var themeName: String {
        let light = KeyTheme.all.first { $0.id == model.settings.themeLight }?.name ?? ""
        let dark = KeyTheme.all.first { $0.id == model.settings.themeDark }?.name ?? ""
        return light == dark ? light : "\(light)／\(dark)"
    }

    private func row(_ title: String, detail: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(Color.primary)
                Spacer()
                if let detail {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 配色

    private var themePage: some View {
        Form {
            Section("ライトモード") { themePicker($model.settings.themeLight) }
            Section("ダークモード") { themePicker($model.settings.themeDark) }
        }
        .environment(\.defaultMinListRowHeight, 40)
        .listSectionSpacing(.compact)
    }

    private func themePicker(_ selection: Binding<String>) -> some View {
        ForEach(KeyTheme.all, id: \.id) { t in
            Button {
                selection.wrappedValue = t.id
            } label: {
                HStack {
                    Text(t.name).foregroundStyle(Color.primary)
                    Spacer()
                    if selection.wrappedValue == t.id {
                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }

    // MARK: - 設定の保存と呼び出し

    private var presetPage: some View {
        Form {
            Section {
                Button("今の設定を保存") { model.savePreset() }
            } footer: {
                Text("5つまで保存できます。")
            }
            if !model.presets.isEmpty {
                Section("保存した設定") {
                    ForEach(model.presets) { p in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name)
                                Text(shapeName(p.settings)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("呼び出す") { model.loadPreset(p) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            Button(role: .destructive) { model.deletePreset(p) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .environment(\.defaultMinListRowHeight, 40)
        .listSectionSpacing(.compact)
    }

    private func shapeName(_ s: KeyboardSettings) -> String {
        switch s.shape {
        case .standard: return "両手"
        case .rightGrid: return s.hand == .right ? "片手・格子・右手" : "片手・格子・左手"
        case .fan: return s.hand == .right ? "片手・扇形・右手" : "片手・扇形・左手"
        }
    }

    // MARK: - ユーザー辞書

    private var dictionaryPage: some View {
        Form {
            if dictionary.words.isEmpty {
                Text("登録した単語はまだありません。「単語登録」から追加できます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(dictionary.words) { w in
                    HStack {
                        Text(w.word)
                        Text(w.reading).font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) { dictionary.remove(w) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .environment(\.defaultMinListRowHeight, 40)
    }

    // MARK: - 変換の診断

    private var diagnosisPage: some View {
        ScrollView {
            Text(diagnosis)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }
}

/// キーを見ながら大きさを変える細い帯。キーボードの上に出し、変えるとすぐ下に反映される。
struct AdjustBar: View {
    @ObservedObject var model: SettingsModel
    let onBack: () -> Void
    let onClose: () -> Void
    @State private var selectedID = "h"

    private var params: [TuningParam] {
        TuningParams.all.filter { $0.shapes.contains(model.settings.shape) }
    }
    private var current: TuningParam? {
        params.first { $0.id == selectedID } ?? params.first
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Label("設定", systemImage: "chevron.left").font(.footnote)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(params) { p in
                            chip(p.label, on: p.id == current?.id) { selectedID = p.id }
                        }
                    }
                }
                Button("完了", action: onClose)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(on ? Color.accentColor : Color(uiColor: .secondarySystemBackground)))
                .foregroundStyle(on ? Color.white : Color.primary)
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
}
