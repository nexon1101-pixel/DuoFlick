import SwiftUI
import UIKit

/// 本物のキーボードの描画（KeyboardView）を、そのままアプリの中に出すプレビュー。
/// 内側画面（幅の広いほう）は、実際の幅で組んでから、画面に収まるよう縮めて出す。
final class PreviewContainer: UIView {
    let kv = KeyboardView(frame: .zero)
    var profile: ScreenProfile = .narrow

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Palette.background
        clipsToBounds = true
        layer.cornerRadius = 12
        kv.isUserInteractionEnabled = false
        kv.backgroundColor = .clear
        addSubview(kv)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 組むときの幅（実機のキーボードの幅に近い値）と、画面に収めるための縮小率
    static func metrics(profile: ScreenProfile, available: CGFloat) -> (width: CGFloat, scale: CGFloat) {
        let w: CGFloat = profile == .narrow ? 390 : 669
        return (w, min(1, max(available, 100) / w))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let m = Self.metrics(profile: profile, available: bounds.width)
        kv.transform = .identity
        kv.bounds = CGRect(x: 0, y: 0, width: m.width, height: kv.requiredHeight(for: m.width))
        kv.transform = CGAffineTransform(scaleX: m.scale, y: m.scale)
        kv.center = CGPoint(x: bounds.width / 2, y: kv.bounds.height * m.scale / 2)
    }
}

/// プレビューのキーボードを、画面側から操作するための入れ物（補正のリセットなど）
final class PreviewHandle: ObservableObject {
    weak var container: PreviewContainer?
}

struct KeyboardPreview: UIViewRepresentable {
    let settings: KeyboardSettings
    let grip: Grip
    let mode: InputMode
    let profile: ScreenProfile
    let showCorrection: Bool
    let handle: PreviewHandle

    func makeUIView(context: Context) -> PreviewContainer {
        let v = PreviewContainer(frame: .zero)
        handle.container = v
        return v
    }

    func updateUIView(_ v: PreviewContainer, context: Context) {
        v.profile = profile
        v.kv.grip = grip
        v.kv.mode = mode
        v.kv.settings = settings
        v.kv.showCorrection = showCorrection
        v.kv.setNeedsDisplay()
        v.setNeedsLayout()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PreviewContainer, context: Context) -> CGSize? {
        let avail = proposal.width ?? 390
        let m = PreviewContainer.metrics(profile: profile, available: avail)
        let h = KeyboardLayout.make(settings: settings, mode: mode, grip: grip, width: m.width).height
        return CGSize(width: avail, height: ceil(h * m.scale))
    }
}

/// アプリの設定画面。上に本物のキーボードを出し、下で形・大きさ・入力などを変える。
/// 変えた設定は共有の保存先に書かれ、キーボードを開いたときに読み込まれる。
struct DesignScreen: View {
    @StateObject private var model = SettingsModel()
    @State private var profile: ScreenProfile = .narrow
    @State private var grip: Grip = .one
    @State private var mode: InputMode = .kana
    @State private var history: [KeyboardSettings] = []
    @State private var lastPush = Date.distantPast
    @State private var confirmReset = false
    @State private var backupMessage = ""
    @StateObject private var handle = PreviewHandle()
    @State private var showCorrection = false
    @State private var offsetText = ""
    @State private var trial = ""

    var body: some View {
        GeometryReader { geo in
            if geo.size.width >= 700 {
                // 広い画面（Duo の内側画面など）は、左にプレビュー、右に調整を並べる
                HStack(spacing: 0) {
                    ScrollView { previewPane }
                        .frame(width: min(geo.size.width * 0.5, 560))
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                    Divider()
                    settingsForm
                }
            } else {
                VStack(spacing: 0) {
                    previewPane
                    Divider()
                    settingsForm
                }
            }
        }
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if let prev = history.popLast() { model.settings = prev }
                } label: {
                    Label("元に戻す", systemImage: "arrow.uturn.backward")
                }
                .disabled(history.isEmpty)
            }
        }
        .onAppear { model.select(profile: profile, grip: grip) }
        .onChange(of: model.settings) { _, _ in SettingsSignal.post() }
        .onChange(of: profile) { _, _ in switchContext() }
        .onChange(of: grip) { _, _ in switchContext() }
    }

    private var previewPane: some View {
        VStack(spacing: 8) {
            Picker("画面", selection: $profile) {
                Text("外側画面").tag(ScreenProfile.narrow)
                Text("内側画面").tag(ScreenProfile.wide)
            }
            .pickerStyle(.segmented)
            HStack(spacing: 8) {
                Picker("持ち方", selection: $grip) {
                    Text("片手持ち").tag(Grip.one)
                    Text("両手持ち").tag(Grip.two)
                }
                .pickerStyle(.segmented)
                Picker("面", selection: $mode) {
                    Text("かな").tag(InputMode.kana)
                    Text("英字").tag(InputMode.qwerty)
                    Text("記号").tag(InputMode.symbol)
                }
                .pickerStyle(.segmented)
            }
            KeyboardPreview(settings: model.settings, grip: grip, mode: mode, profile: profile,
                            showCorrection: showCorrection, handle: handle)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
            if profile == .wide {
                Text("内側画面は、実際のキーボードの幅（約669pt）で組んで、収まらないときは縮めて表示しています。").font(.caption2).foregroundStyle(.secondary)
            }
            Toggle("補正を見る（赤い点：当たりやすい位置、黄色の線：方向の境目）", isOn: $showCorrection)
                .font(.footnote)
                .onChange(of: showCorrection) { _, on in
                    if on { handle.container?.kv.reloadCorrection() }
                    offsetText = handle.container?.kv.offsetDescription ?? ""
                }
            if showCorrection {
                HStack {
                    Text(offsetText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("ずれ補正をリセット") {
                        handle.container?.kv.resetOffset()
                        handle.container?.kv.reloadCorrection()
                        offsetText = handle.container?.kv.offsetDescription ?? ""
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("試し打ち").font(.footnote.weight(.semibold))
                TextEditor(text: $trial)
                    .frame(height: 90)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: .systemBackground)))
                Text("ここをタップして、地球儀キーでDuoFlickに切り替えると、本物のキーボードで試せます。設定を変えると、開いているキーボードにもすぐ反映されます。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private var settingsForm: some View {
        Form {
            if !SharedStore.isShared {
                Section {
                    Text("キーボードと設定を共有できていません。ここで変えても、キーボードには反映されません（ホームの「共有の状態」を見てください）。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            shapeSection
            sizeSection
            inputSection
            lookSection
            presetSection
            otherSection
        }
        .environment(\.defaultMinListRowHeight, 40)
    }

    private func switchContext() {
        history.removeAll()
        model.select(profile: profile, grip: grip)
    }

    // MARK: - 変更の入口（元に戻すの記録つき）

    private func edit(_ change: (inout KeyboardSettings) -> Void) {
        var s = model.settings
        change(&s)
        guard s != model.settings else { return }
        // スライダーを動かしている間は、続けて記録しない
        if Date().timeIntervalSince(lastPush) > 0.6 {
            history.append(model.settings)
            if history.count > 30 { history.removeFirst() }
        }
        lastPush = Date()
        model.settings = s
    }

    private func bind<T: Equatable>(_ kp: WritableKeyPath<KeyboardSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: kp] }, set: { v in edit { $0[keyPath: kp] = v } })
    }

    // MARK: - 形

    private var shapeSection: some View {
        Section("形") {
            Picker("形", selection: bind(\.shape)) {
                Text("両手").tag(KeyboardShape.standard)
                Text("片手・格子").tag(KeyboardShape.rightGrid)
                Text("片手・扇形").tag(KeyboardShape.fan)
            }
            .pickerStyle(.segmented)
            if model.settings.shape != .standard {
                Picker("手", selection: bind(\.hand)) {
                    Text("右手").tag(Hand.right)
                    Text("左手").tag(Hand.left)
                }
                .pickerStyle(.segmented)
            }
            if model.settings.shape == .fan {
                Toggle("文字を扇に沿わせる", isOn: bind(\.followFan))
            }
        }
    }

    // MARK: - 大きさと位置

    private var sizeSection: some View {
        Section {
            ForEach(TuningParams.all.filter { $0.shapes.contains(model.settings.shape) }) { p in
                VStack(spacing: 2) {
                    HStack {
                        Text(p.label)
                        Spacer()
                        Text(TuningParams.format(p, model.settings[keyPath: p.keyPath]))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Button { nudge(p, -p.step) } label: {
                            Image(systemName: "minus.circle.fill").font(.title3)
                        }
                        .buttonStyle(.borderless)
                        Slider(value: bind(p.keyPath), in: p.range, step: p.step)
                        Button { nudge(p, p.step) } label: {
                            Image(systemName: "plus.circle.fill").font(.title3)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        } header: {
            Text("大きさと位置")
        } footer: {
            Text("上のキーボードがすぐに変わります。")
        }
    }

    private func nudge(_ p: TuningParam, _ delta: Double) {
        edit { $0[keyPath: p.keyPath] = TuningParams.clamp(p, $0[keyPath: p.keyPath] + delta) }
    }

    // MARK: - 入力

    private var inputSection: some View {
        Section("入力") {
            Toggle("押したときの振動", isOn: bind(\.haptics))
            Toggle("続けてタップで文字を切り替え", isOn: bind(\.toggleTap))
            Toggle("ずれ補正（押す位置と斜めのくせ）", isOn: bind(\.autoCorrect))
            Toggle("打ち間違いの候補（試験的）", isOn: bind(\.typoCorrection))
            Toggle("内側画面の片手持ちをiOS標準の配置にする", isOn: bind(\.iosLayout))
            Toggle("両手持ちで、かなを左右に分ける", isOn: bind(\.splitKana))
            Toggle("変換待ちの間は、ABC・地球儀など入力を中断するキーを止める", isOn: bind(\.lockWhileComposing))
        }
    }

    // MARK: - 見た目

    private var lookSection: some View {
        Section("見た目") {
            Picker("配色（ライト）", selection: bind(\.themeLight)) {
                ForEach(KeyTheme.all, id: \.id) { Text($0.name).tag($0.id) }
            }
            Picker("配色（ダーク）", selection: bind(\.themeDark)) {
                ForEach(KeyTheme.all, id: \.id) { Text($0.name).tag($0.id) }
            }
        }
    }

    // MARK: - 保存と呼び出し

    private var presetSection: some View {
        Section {
            Button("今の設定を保存") { model.savePreset() }
            ForEach(model.presets) { p in
                HStack {
                    Text(p.name)
                    Spacer()
                    Button("呼び出す") {
                        history.append(model.settings)
                        model.loadPreset(p)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button(role: .destructive) { model.deletePreset(p) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("設定の保存と呼び出し")
        } footer: {
            Text("5つまで保存できます。")
        }
    }

    // MARK: - その他

    private var otherSection: some View {
        Section {
            Button("バックアップをコピーする") {
                UIPasteboard.general.string = Backup.makeJSON() ?? ""
                backupMessage = "コピーしました。メモなどに貼って取っておいてください"
            }
            Button("コピーしたバックアップから戻す") {
                let text = UIPasteboard.general.string ?? ""
                if let n = Backup.restore(from: text) {
                    history.removeAll()
                    model.select(profile: profile, grip: grip)
                    model.reload()
                    backupMessage = "\(n)項目を戻しました"
                } else {
                    backupMessage = "バックアップの形ではありません"
                }
            }
            if !backupMessage.isEmpty {
                Text(backupMessage).font(.footnote).foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                if confirmReset {
                    edit { $0 = KeyboardSettings(shape: $0.shape) }
                    confirmReset = false
                } else {
                    confirmReset = true
                }
            } label: {
                Text(confirmReset ? "もう一度押すと、標準の配置に戻します" : "標準の配置から始め直す")
            }
        } header: {
            Text("その他")
        } footer: {
            Text("ずれ補正のリセット・単語登録・定型文などは、キーボードの中の設定（地球儀キーを上にフリック）にあります。")
        }
    }
}
