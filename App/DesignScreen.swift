import SwiftUI
import UIKit

/// 本物のキーボードの描画（KeyboardView）を、そのままアプリの中に出すプレビュー。
/// 内側画面（幅の広いほう）は、実際の幅で組んでから、画面に収まるよう縮めて出す。
/// 保存済みのキーの位置を、点線で重ねて出す（どこがどう動いたか見えるように）
final class GhostView: UIView {
    var paths: [UIBezierPath] = [] {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        UIColor.systemOrange.setStroke()
        for p in paths {
            p.lineWidth = 1.5
            p.setLineDash([4, 3], count: 2, phase: 0)
            p.stroke()
        }
    }
}

final class PreviewContainer: UIView {
    let kv = KeyboardView(frame: .zero)
    let ghost = GhostView(frame: .zero)
    var profile: ScreenProfile = .narrow
    var typing = false {
        didSet { kv.isUserInteractionEnabled = typing }
    }
    /// 保存済みの設定（いまの設定と違うときだけ入れる）
    var reference: KeyboardSettings? {
        didSet { setNeedsLayout() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Palette.background
        clipsToBounds = true
        layer.cornerRadius = 12
        kv.isUserInteractionEnabled = false
        kv.backgroundColor = .clear
        addSubview(kv)
        addSubview(ghost)
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
        ghost.transform = .identity
        ghost.bounds = kv.bounds
        ghost.transform = kv.transform
        ghost.center = kv.center
        if let ref = reference {
            ghost.paths = KeyboardLayout.make(settings: ref, mode: kv.mode, grip: kv.grip, width: m.width).keys.map { $0.path }
        } else {
            ghost.paths = []
        }
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
    let reference: KeyboardSettings?
    let handle: PreviewHandle
    var typing = false
    var onType: ((KeyDef, FlickDirection) -> Void)? = nil

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
        v.typing = typing
        v.kv.onKey = onType
        v.reference = reference
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
    @State private var typing = false
    @State private var tab: Tab = .layout
    @State private var forceOpen = false
    /// 編集中の設定。「保存して反映」を押すまで、キーボードには渡さない
    @State private var draft = KeyboardSettings()

    var body: some View {
        GeometryReader { geo in
            if geo.size.width <= 480 && !forceOpen {
                // 外側画面（折りたたんだ状態）では、プレビューと調整が入りきらない
                foldedNotice
            } else {
                VStack(spacing: 0) {
                    if geo.size.width >= 700 {
                        // 広い画面（Duo の内側画面を横にした状態など）は、左にプレビュー、右に調整を並べる
                        HStack(spacing: 20) {
                            ScrollView { previewPane }
                                .frame(width: min(geo.size.width * 0.5, 560))
                                .background(Color(uiColor: .secondarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                            settingsForm
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    } else {
                        previewPane
                        Divider()
                        settingsForm
                    }
                    saveBar
                }
            }
        }
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if let prev = history.popLast() { draft = prev }
                } label: {
                    Label("元に戻す", systemImage: "arrow.uturn.backward")
                }
                .disabled(history.isEmpty)
            }
        }
        .onAppear {
            model.select(profile: profile, grip: grip)
            draft = model.settings
        }
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
            KeyboardPreview(settings: draft, grip: grip, mode: mode, profile: profile,
                            showCorrection: showCorrection,
                            reference: dirty ? model.settings : nil, handle: handle,
                            typing: typing, onType: typeKey)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
            if profile == .wide {
                Text("内側画面は、実際のキーボードの幅（約669pt）で組んで、収まらないときは縮めて表示しています。").font(.caption2).foregroundStyle(.secondary)
            }
            Toggle("このキーボードで試し打ちする", isOn: $typing)
                .font(.footnote)
            Toggle("補正を見る", isOn: $showCorrection)
                .font(.footnote)
                .onChange(of: showCorrection) { _, on in
                    if on { handle.container?.kv.reloadCorrection() }
                    offsetText = handle.container?.kv.offsetDescription ?? ""
                }
            if showCorrection {
                Text("赤い点：指が当たりやすい位置　黄色の線：方向の境目").font(.caption2).foregroundStyle(.secondary)
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
                Text("ここをタップして、地球儀キーでDuoFlickに切り替えると、本物のキーボードで試せます。「保存して反映」を押すと、開いているキーボードにもすぐ反映されます。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private var foldedNotice: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.portrait.arrowtriangle.2.outward")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Duo を開いてください")
                .font(.title3.weight(.semibold))
            Text("この設定は、Duo を開いた状態（内側画面）で使う前提です。いまは外側画面で開いていて、プレビューと調整が入りきりません。Duo を開くと、そのまま設定を続けられます。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("外側画面のまま開く") { forceOpen = true }
                .buttonStyle(.bordered)
                .padding(.top, 6)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var saveBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                if dirty {
                    Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("未保存の変更があります").font(.footnote.weight(.semibold))
                        Text("点線が、保存済みのキーの位置です").font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("保存済み（キーボードに反映されています）").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Button("破棄") {
                    draft = model.settings
                    history.removeAll()
                }
                .buttonStyle(.bordered)
                .disabled(!dirty)
                Button("保存して反映") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!dirty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private enum Tab: String, CaseIterable, Identifiable {
        case layout = "配置", input = "入力", look = "見た目", data = "データ"
        var id: String { rawValue }
    }

    private var settingsForm: some View {
        VStack(spacing: 0) {
            Picker("項目", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Form {
                if !SharedStore.isShared {
                    Section {
                        Text("キーボードと設定を共有できていません。ここで変えても、キーボードには反映されません（ホームの「共有の状態」を見てください）。")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                switch tab {
                case .layout:
                    shapeSection
                    sizeSection
                    detailSection
                case .input:
                    inputSection
                    cursorSection
                    convertSection
                case .look:
                    lookSection
                case .data:
                    presetSection
                    otherSection
                }
            }
            .environment(\.defaultMinListRowHeight, 40)
        }
    }

    private func switchContext() {
        history.removeAll()
        model.select(profile: profile, grip: grip)
        draft = model.settings
    }

    private var dirty: Bool { draft != model.settings }

    private func save() {
        model.settings = draft
        SettingsSignal.post()
    }

    // MARK: - 変更の入口（元に戻すの記録つき）

    private func edit(_ change: (inout KeyboardSettings) -> Void) {
        var s = draft
        change(&s)
        guard s != draft else { return }
        // スライダーを動かしている間は、続けて記録しない
        if Date().timeIntervalSince(lastPush) > 0.6 {
            history.append(draft)
            if history.count > 30 { history.removeFirst() }
        }
        lastPush = Date()
        draft = s
    }

    private func bind<T: Equatable>(_ kp: WritableKeyPath<KeyboardSettings, T>) -> Binding<T> {
        Binding(get: { draft[keyPath: kp] }, set: { v in edit { $0[keyPath: kp] = v } })
    }

    // MARK: - 配置

    private var shapeSection: some View {
        Section {
            Picker("形", selection: bind(\.shape)) {
                Text("両手").tag(KeyboardShape.standard)
                Text("片手・格子").tag(KeyboardShape.rightGrid)
                Text("片手・扇形").tag(KeyboardShape.fan)
            }
            .pickerStyle(.segmented)
            if draft.shape != .standard {
                Picker("手", selection: bind(\.hand)) {
                    Text("右手").tag(Hand.right)
                    Text("左手").tag(Hand.left)
                }
                .pickerStyle(.segmented)
            }
            if draft.shape == .fan {
                toggleRow("文字を扇に沿わせる", "文字とフリックの向きを、キーの傾きに合わせます", bind(\.followFan))
            }
        } header: {
            Text("1. 形を選ぶ")
        }
    }

    /// よく使う調整。残りは「細かい調整」にまとめる
    /// プレビューのキーボードで打った文字を、試し打ちの欄に入れる（変換はしない）
    private func typeKey(_ def: KeyDef, _ dir: FlickDirection) {
        switch def.action {
        case .kana(let a), .direct(let a):
            if dir.rawValue < a.count, !a[dir.rawValue].isEmpty { trial += a[dir.rawValue] }
        case .space: trial += " "
        case .newline: trial += "\n"
        case .delete: if !trial.isEmpty { trial.removeLast() }
        case .layer(let m): mode = m
        default: break
        }
    }

    private static let mainIDs = ["w", "h", "r", "a", "m"]

    private func params(main: Bool) -> [TuningParam] {
        TuningParams.all.filter {
            $0.shapes.contains(draft.shape) && $0.id != "l" && $0.id != "c" && (Self.mainIDs.contains($0.id) == main)
        }
    }

    private var sizeSection: some View {
        Section {
            ForEach(params(main: true)) { sliderRow($0) }
        } header: {
            Text("2. 大きさを合わせる")
        } footer: {
            Text("上のキーボードがすぐに変わります。")
        }
    }

    private var detailSection: some View {
        Section {
            DisclosureGroup("細かい調整（余白・フリック距離・傾きなど）") {
                ForEach(params(main: false)) { sliderRow($0) }
            }
        }
    }

    private static let helps: [String: String] = [
        "w": "キー1つの横幅。画面に収まらないときは自動で縮みます",
        "h": "キー1つの縦の長さ",
        "r": "扇のカーブの半径。小さいほど急に曲がります",
        "a": "扇を回す向き",
        "m": "画面の端からキーまでの余白。両手持ちは、小さくするほどキーが端まで広がります",
        "s": "両手持ちの分割で、左右のキーの間の空き。広いほどキーが細くなります",
        "b": "キーボードの下の余白",
        "f": "指を何mm動かすとフリックと判定するか",
        "g": "キーとキーのすき間",
        "e": "親指から遠いキーを大きくする割合",
        "t": "フリックの方向の判定を、全体で回す角度",
        "l": "キーの文字の大きさ",
        "c": "空白キーを長押ししてカーソルを動かすときの速さ。速く動かすと、さらに大きく進みます",
    ]

    private func sliderRow(_ p: TuningParam) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(p.label)
                Spacer()
                Text(TuningParams.format(p, draft[keyPath: p.keyPath]))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let h = Self.helps[p.id] {
                Text(h).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
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

    private func nudge(_ p: TuningParam, _ delta: Double) {
        edit { $0[keyPath: p.keyPath] = TuningParams.clamp(p, $0[keyPath: p.keyPath] + delta) }
    }

    /// 題名と、短い説明をつけたトグル
    private func toggleRow(_ title: String, _ caption: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 入力

    private var inputSection: some View {
        Section("打ち心地") {
            toggleRow("振動", "キーを押したときに震えます", bind(\.haptics))
            toggleRow("続けてタップで切り替え", "同じキーを続けて押すと あ→い→う と変わります", bind(\.toggleTap))
            toggleRow("ずれ補正", "押す位置と斜めのくせを覚えて、判定を直します", bind(\.autoCorrect))
            toggleRow("変換待ちは入力を中断するキーを止める", "読みに下線が出ている間、ABC・地球儀などを押せなくします", bind(\.lockWhileComposing))
        }
    }

    private var cursorSection: some View {
        Section {
            if let p = TuningParams.all.first(where: { $0.id == "c" }) { sliderRow(p) }
        } header: {
            Text("カーソル移動（空白キー長押し）")
        }
    }

    private var convertSection: some View {
        Group {
            Section("配置の切り替え") {
                toggleRow("内側画面の片手持ちをiOS標準の配置にする", "左にキー、真ん中に候補、右にかなを並べます", bind(\.iosLayout))
                toggleRow("両手持ちで、かなを左右に分ける", "ピンチアウト／ピンチインでも切り替えられます", bind(\.splitKana))
            }
            Section("変換") {
                toggleRow("打ち間違いの候補（試験的）", "打ち間違いを直した候補も出します", bind(\.typoCorrection))
            }
        }
    }

    // MARK: - 見た目

    private var lookSection: some View {
        Group {
            Section("配色") {
                Picker("ライトモード", selection: bind(\.themeLight)) {
                    ForEach(KeyTheme.all, id: \.id) { Text($0.name).tag($0.id) }
                }
                Picker("ダークモード", selection: bind(\.themeDark)) {
                    ForEach(KeyTheme.all, id: \.id) { Text($0.name).tag($0.id) }
                }
            }
            if let p = TuningParams.all.first(where: { $0.id == "l" }) {
                Section("文字") { sliderRow(p) }
            }
        }
    }

    // MARK: - 保存と呼び出し

    private var presetSection: some View {
        Section {
            Button("今の設定を保存") { model.savePreset(draft) }
            ForEach(model.presets) { p in
                HStack {
                    Text(p.name)
                    Spacer()
                    Button("呼び出す") {
                        history.append(draft)
                        draft = p.settings
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
                    draft = model.settings
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
