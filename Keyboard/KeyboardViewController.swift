import UIKit
import SwiftUI

final class KeyboardViewController: UIInputViewController {
    private let model = SettingsModel()
    private let dictionary = UserDictionaryStore()
    private let keyboardView = KeyboardView()
    private let candidateBar = CandidateBar()
    /// 候補の一覧（UIKit）。作り直さず使い回し、開閉は isHidden の切り替えで行う。
    private lazy var candidateListView: CandidateListView = {
        let v = CandidateListView()
        v.isHidden = true
        v.translatesAutoresizingMaskIntoConstraints = false
        v.onSelect = { [weak self] i in self?.selectFromCandidateList(i) }
        return v
    }()
    /// 一覧が開いているかどうか。アニメーション中も含め、こちらの状態が正。
    /// 従来はホストの有無で判断していたため、閉じるアニメーション中に
    /// ∨を押すと「開いていない」と判断して開き直してしまっていた。
    private var isCandidateListOpen = false
    private let guideView = GuideOverlayView()
    private let composer = Composer()
    private let optimizer = OptimizerModel()
    /// 打ち比べの最中（キー入力はお題の採点に使い、入力欄には入れない）
    private var optimizing = false
    private let phrases = PhraseStore()
    private let clipboard = ClipboardStore()
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private let flickHaptic = UISelectionFeedbackGenerator()
    private var clipboardTimer: Timer?
    private var heightConstraint: NSLayoutConstraint?
    private var keyboardTop: NSLayoutConstraint?
    private lazy var barHeight = candidateBar.heightAnchor.constraint(equalToConstant: CandidateBar.height)

    /// 候補の帯の高さ。ライブ変換のときと、範囲選択中（範囲の読みを出す）は、読みを出す余白のぶんだけ高くする
    private func updateBarHeight() {
        let margin = (model.settings.liveConversion || composer.rangeMode) ? CandidateBar.readingMargin : 0
        let h = CandidateBar.height + margin
        if barHeight.constant != h { barHeight.constant = h }
        candidateBar.topMargin = margin
        if keyboardView.topInset != h { keyboardView.topInset = h }
    }
    private var lastWidth: CGFloat = 0
    private var mode: InputMode = .kana

    /// キーボードの上に重ねて出す画面（調整バー・単語登録）
    private var topHost: UIViewController?
    private var topHeight: CGFloat = 0
    private let adjustHeight: CGFloat = 92
    private let registerHeight: CGFloat = 112
    private var register: RegisterModel?

    /// 直前に確定した文字と読み（↺で取り消すため）
    private var lastCommit: (text: String, reading: String)?

    override func viewDidLoad() {
        super.viewDidLoad()
        // 背景はiOS標準のキーボード背景（角の丸い枠）をそのまま使う
        view.backgroundColor = .clear
        // アプリ本体の設定画面で設定が変わったら、すぐ読み直す
        SettingsSignal.observe { [weak self] in
            guard let self else { return }
            self.model.reload()
            self.keyboardView.grip = self.model.grip
            self.dictionary.reload()
            self.phrases.reload()
        }

        for v in [keyboardView, candidateBar, guideView] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        // 一覧は一度だけ作り、隠したまま置いておく。開閉で作り直さない。
        view.addSubview(candidateListView)
        NSLayoutConstraint.activate([
            candidateListView.topAnchor.constraint(equalTo: candidateBar.bottomAnchor),
            candidateListView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            candidateListView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            candidateListView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        NSLayoutConstraint.activate([
            keyboardView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboardView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            // 変換候補の帯はキーボードの上部に重ねる（キーはその下から並ぶ）
            candidateBar.topAnchor.constraint(equalTo: keyboardView.topAnchor),
            candidateBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            candidateBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            barHeight,
            // フリックの十字ガイドは帯の上にも重ねて描く
            guideView.topAnchor.constraint(equalTo: keyboardView.topAnchor),
            guideView.bottomAnchor.constraint(equalTo: keyboardView.bottomAnchor),
            guideView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            guideView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        let top = keyboardView.topAnchor.constraint(equalTo: view.topAnchor)
        top.isActive = true
        keyboardTop = top

        let height = view.heightAnchor.constraint(equalToConstant: 300)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        heightConstraint = height

        keyboardView.topInset = CandidateBar.height
        keyboardView.guideView = guideView
        keyboardView.grip = model.grip
        keyboardView.settings = model.settings
        keyboardView.onPanelRect = { [weak self] rect in self?.updateMiddlePanel(rect) }
        keyboardView.onPinch = { [weak self] split in self?.setSplit(split) }
        keyboardView.onKey = { [weak self] def, dir in self?.handle(def, dir) }
        keyboardView.onFlickChange = { [weak self] in
            guard let self, self.model.settings.haptics, self.hasFullAccess else { return }
            self.flickHaptic.selectionChanged()
        }
        keyboardView.onPress = { [weak self] in
            guard let self, self.model.settings.haptics, self.hasFullAccess else { return }
            self.haptic.impactOccurred()
        }
        keyboardView.onSpaceHold = { [weak self] in self?.spaceHold() }
        keyboardView.onCursor = { [weak self] steps in self?.cursorDrag(steps) }
        keyboardView.onCursorVertical = { [weak self] lines in self?.moveCursorVertically(lines) }
        candidateBar.onSelect = { [weak self] i in self?.selectFromBar(i) }
        candidateBar.onRangeBegan = { [weak self] i in self?.rangePressBegan(i) }
        candidateBar.onRangeDragged = { [weak self] dx in self?.rangePressDragged(dx) }
        candidateBar.onRangeEnded = { [weak self] in self?.rangePressEnded() }
        candidateBar.onReading = { [weak self] in self?.commitReadingAsIs() }
        candidateBar.onExpand = { [weak self] in self?.toggleCandidateList() }
        candidateBar.onSwipeDown = { [weak self] in
            // 帯を下にフリックしたら、入力中の文字を確定してキーボードを閉じる
            self?.commitAll()
            self?.dismissKeyboard()
        }

        composer.userWords = dictionary.words
        dictionary.onChange = { [weak self] in
            guard let self else { return }
            self.composer.userWords = self.dictionary.words
        }
        model.onChange = { [weak self] s in
            guard let self else { return }
            self.keyboardView.grip = self.model.grip
            self.keyboardView.settings = s
            self.updateHeight(force: true)
            // 矢印はレイアウト任せだと「次の文字入力まで」古い位置のままになるので即時更新（v0.37.27）
            self.updateFanDockButton()
        }
        refreshBar()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        view.transform = .identity
        view.alpha = 1
        // アプリ本体の設定画面で変えた設定を読み直す
        model.reload()
        updateFanDockButton()
        keyboardView.grip = model.grip
        dictionary.reload()
        phrases.reload()
        applyKeyboardType()
        haptic.prepare()
        flickHaptic.prepare()
        // キーボードを開いている間にコピーされたものを、クリップボードの履歴に残す
        if hasFullAccess {
            importAppSettings()
            clipboard.capture()
            clipboardTimer?.invalidate()
            clipboardTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.clipboard.capture()
                // 開いた直後は貼り付けチップの判定が間に合わないことがあるので、後から出し直す
                if self.composer.isEmpty, !self.pasteChip, !self.imageChip { self.refreshBar() }
            }
        }
        // 開くたびに帯を出し直す。立ち上げ直後（viewDidLoad）の初回判定だけでは、
        // 読み取り自体はできていても貼り付けチップが出ないことがあるため
        refreshBar()
    }

    /// 設定の取り込みで最後に確認したクリップボードの変更回数
    private var lastImportChangeCount: Int?

    /// アプリ本体の設定画面からコピーされた設定があれば読み込む（読んだら、クリップボードの印の入った文字は消す）
    /// クリップボードが変わっていないときは中身を読まない（開くたびに読むと、
    /// 他アプリからの読み取り承認が先に消費されて、貼り付けが初回だけ失敗する）。
    /// 文字があるのに読めない（承認待ち）ときは印を進めず、次に開いたときにもう一度試す
    private func importAppSettings() {
        let pb = UIPasteboard.general
        guard pb.changeCount != lastImportChangeCount else { return }
        guard pb.hasStrings else { lastImportChangeCount = pb.changeCount; return }
        guard let text = pb.string else { return }
        lastImportChangeCount = pb.changeCount
        guard let prefs = SharedPrefs.decode(text) else { return }
        UIPasteboard.general.string = ""
        KeyboardSettings.applyShared(prefs)
        var s = model.settings
        s.apply(prefs)
        model.settings = s
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        commitAll()
        composer.save()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // 外側画面と内側画面で、別々の設定を使う
        if view.bounds.width > 0 {
            model.use(profile: ScreenProfile.forWidth(view.bounds.width))
        }
        updateHeight(force: false)
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        applyKeyboardType()
        updateKeyLabels()
        scheduleEmptyCheck()
    }

    /// LINEなどで送信すると、入力欄が外から空にされる。キーボードは予測（確定した語の続き）を持ったままなので、
    /// 送った文字の続きが候補に出続けた。入力欄が空になったら、予測と「直前の確定」を捨てる
    private var emptyCheckWork: DispatchWorkItem?
    private var contextSeen = false
    private func scheduleEmptyCheck(after delay: TimeInterval = 0.4) {
        emptyCheckWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let proxy = self.textDocumentProxy
            let before = proxy.documentContextBeforeInput ?? ""
            let after = proxy.documentContextAfterInput ?? ""
            // 変換待ちのまま送信されたとき：アプリが下線付きの文字ごと入力欄を空にしている。読みと候補を捨てる
            if !self.composer.isEmpty {
                if self.markedActive, self.markedVisible, before.isEmpty, after.isEmpty, !proxy.hasText {
                    self.composer.reset()
                    self.markedActive = false
                    self.markedVisible = false
                    self.lastCommit = nil
                    self.keyboardView.resetFlickHistory()
                    self.hideCandidateList()
                    self.refreshBar()
                } else if self.markedActive, self.markedVisible {
                    // 入力欄が変わったと知らされないアプリもあるので、変換待ちのあいだは見張り続ける
                    self.scheduleEmptyCheck(after: 0.6)
                }
                return
            }
            self.markedVisible = false
            if !before.isEmpty || !after.isEmpty { self.contextSeen = true; return }
            guard self.contextSeen else { return }
            guard !self.composer.predictionTexts.isEmpty || self.lastCommit != nil || !self.domainCandidates.isEmpty else { return }
            self.composer.clearPredictions()
            self.lastCommit = nil
            self.domainCandidates = []
            self.contextSeen = false
            self.refreshBar()
        }
        emptyCheckWork = work
        // 確定の直後は、入力欄の中身が反映される前に呼ばれることがあるので、少し待ってから確かめる
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 入力欄の種類に合わせて、最初の文字種を選ぶ
    private var lastKeyboardType: UIKeyboardType?
    private func applyKeyboardType() {
        let type = textDocumentProxy.keyboardType ?? .default
        guard type != lastKeyboardType else { return }
        lastKeyboardType = type
        switch type {
        case .emailAddress, .URL, .asciiCapable, .twitter:
            japanese = false
            setMode(.qwerty)
        case .numberPad, .phonePad, .decimalPad, .numbersAndPunctuation, .namePhonePad, .asciiCapableNumberPad:
            japanese = false
            setMode(.symbol)
        default:
            // ふつうの入力欄と検索欄（webSearch）は、最後に使っていた文字種（かな／英字／英字のあモード）で開く
            let last = SharedStore.defaults.string(forKey: Self.lastModeKey)
            if last == "qwerty" || last == "qwertyJa" {
                japanese = (last == "qwertyJa")
                setMode(.qwerty)
            } else {
                setMode(.kana)
            }
        }
    }

    private static let lastModeKey = "DuoFlick.lastMode.v1"
    /// 自分で切り替えたときだけ、最後の文字種として覚える（メール欄などで自動で変わったときは覚えない）
    private func saveLastMode() {
        let v: String
        switch mode {
        case .kana: v = "kana"
        case .qwerty: v = japanese ? "qwertyJa" : "qwerty"
        default: return
        }
        SharedStore.defaults.set(v, forKey: Self.lastModeKey)
    }

    private func setMode(_ m: InputMode) {
        if m != .kana { commitAll() }
        mode = m
        keyboardView.mode = m
        if m != .qwerty { shiftState = .off }
        autoCapOff = false
        updateShiftDisplay()
        updateKeyLabels()
        updateHeight(force: true)
    }

    private func updateHeight(force: Bool) {
        let w = view.bounds.width
        guard w > 0 else { return }
        if !force && w == lastWidth { return }
        lastWidth = w
        updateBarHeight()
        let h = keyboardView.requiredHeight(for: w) + topHeight
        if heightConstraint?.constant != h { heightConstraint?.constant = h }
    }

    // MARK: - 入力

    private func handle(_ def: KeyDef, _ dir: FlickDirection) {
        if let reg = register {
            handleRegisterKey(def, dir, reg)
            return
        }
        if optimizing {
            switch def.action {
            case .kana(let chars), .direct(let chars):
                optimizer.input(pick(chars, dir))
            case .settings, .nextKeyboard:
                stopOptimizing()
            default:
                break
            }
            return
        }
        // 範囲だけを変換中で残している間は、空白（候補の選択）以外のキーを、
        // まず状態を解いて読み全体の変換待ちに戻してから処理する。⌫は解くこと自体で消費する
        if soloRemainder != nil {
            switch def.action {
            case .space:
                break
            case .delete:
                cancelSoloRange()
                updateComposition()
                return
            default:
                cancelSoloRange()
                updateComposition()
            }
        }
        domainCandidates = []
        let expectedClose = pairClose
        pairClose = nil
        // 変換待ち（読みに下線が出ている間）は、ABC・片手／両手などの、入力を中断するキーが押せない（設定でオフにできる）
        if composingLocked {
            if !isAllowedWhileComposing(def) { return }
            // 地球儀はタップ（確定してから切り替え）だけ通し、フリック（設定・履歴・定型文）は変換中は止める（v0.37.31）
            if case .nextKeyboard = def.action, dir != .tap { return }
        }
        let proxy = textDocumentProxy
        // ⌫の下フリック：確定の取り消し（↺）
        if case .delete = def.action, dir == .down {
            // 続けてタップの途中なら、ひとつ前の文字に戻す（iOS標準の↺と同じ）
            if let t = toggle, let chars = t.def.flickChars, applyToggle(t.def, chars, step: -1) { return }
            undoCommit()
            return
        }
        if case .newline = def.action, keyboardView.disabledIDs.contains(def.id) { return }
        lastCommit = nil

        // 同じキーを続けてタップしたら、文字を切り替える
        if dir == .tap, let chars = def.flickChars, let t = toggle, t.def.id == def.id,
           model.settings.toggleTap, Date().timeIntervalSince(t.time) < 1.2, applyToggle(def, chars, step: 1) {
            return
        }
        toggle = nil
        if dir == .tap, model.settings.toggleTap, let chars = def.flickChars {
            toggle = ToggleState(def: def, index: 0, time: Date(), output: chars[0])
        }

        switch def.action {
        case .kana(let chars):
            let s = pick(chars, dir)
            // 句読点は読みに足さず、その場で確定してから入れる（iOS標準の動き）。
            // 読みに足すと、後ろに打ち続けた分とひとつの読みになって、まとめて変換されてしまう
            if !composer.isEmpty, ["、", "。", "？", "！"].contains(s) {
                commitAndPunctuate(s)
                return
            }
            // 候補を選んでいたら先に確定する
            if composer.selectedIndex != nil { commitAll() }
            let alts = keyboardView.lastAlts.keyID == def.id ? keyboardView.lastAlts.chars : []
            composer.insert(s, alts: alts)
            updateComposition()
        case .direct(let chars) where def.id.hasPrefix("digit") && !isNumericField:
            // 数字も読みに足して変換する（全角・漢数字の候補が出る。候補を選んでいたら先に確定する）
            if composer.selectedIndex != nil { commitAll() }
            composer.insert(pick(chars, dir))
            updateComposition()
        case .direct(let chars) where japanese && mode != .kana
            && (def.id == "qpunct" || (isLetterKey(def) && !(pick(chars, dir).first?.isLetter ?? true))):
            // あモードの記号：句読点・ー は日本語の形で、数字もそのまま読みに足す（変換の候補が出る）。それ以外の記号はそのまま入れる
            let raw = pick(chars, dir)
            let jp = [",": "、", ".": "。", "?": "？", "!": "！", "-": "ー"]
            if def.id == "qpunct" || raw.first?.isNumber == true {
                let mapped = jp[raw] ?? raw
                // 句読点は、かなのときと同じく、その場で確定してから入れる
                if !composer.isEmpty, ["、", "。", "？", "！"].contains(mapped) {
                    commitAndPunctuate(mapped)
                    return
                }
                if composer.selectedIndex != nil { commitAll() }
                composer.insert(mapped)
                updateComposition()
            } else {
                commitAll()
                composer.clearPredictions()
                proxy.insertText(raw)
                refreshBar()
            }
        case .direct(let chars) where mode == .qwerty && japanese && isLetterKey(def):
            // ローマ字で入力中の読みに足す。大文字はそのまま英字として入れる
            let raw = pick(chars, dir)
            let upper = shiftState != .off
            if shiftState == .on { shiftState = .off }
            if composer.selectedIndex != nil { commitAll() }
            composer.insert(upper ? raw.uppercased() : raw, roman: !upper)
            updateComposition()
        case .direct(let chars):
            commitAll()
            composer.clearPredictions()
            let s = styled(pick(chars, dir))
            if toggle != nil { toggle?.output = s }
            if let close = Self.bracketPairs[s] {
                // 括弧は対で入れて、中にカーソルを置く
                proxy.insertText(s + close)
                proxy.adjustTextPosition(byCharacterOffset: -1)
                pairClose = close
                refreshBar()
                updateShiftDisplay()
                return
            }
            if expectedClose == s, proxy.documentContextAfterInput?.first == Character(s) {
                // 対で入れた閉じ括弧を打ったら、重ねずに外へ出る
                proxy.adjustTextPosition(byCharacterOffset: 1)
                refreshBar()
                return
            }
            proxy.insertText(s)
            // 「@」を打ったら、よく使うメールのドメインを候補に出す
            if s == "@" { domainCandidates = Self.mailDomains }
            refreshBar()
            updateShiftDisplay()
        case .modifier:
            if !composer.isEmpty {
                if let last = composer.reading.last, let next = KeyCatalog.modified(String(last)),
                   composer.replaceLast(with: next) {
                    updateComposition()
                }
            } else if let last = proxy.documentContextBeforeInput?.last,
                      let next = KeyCatalog.modified(String(last)) {
                proxy.deleteBackward()
                proxy.insertText(next)
            }
        case .shift:
            // 1回で次の1文字だけ大文字、すぐにもう1回で固定
            let now = Date()
            let quick = now.timeIntervalSince(lastShiftTap) < 0.35
            if quick, shiftState == .on || autoCapOff {
                // すぐにもう1回押したら固定
                shiftState = .locked
                autoCapOff = false
            } else if shiftState == .off, shouldAutoCapitalize() {
                // 自動で大文字になっているところは、シフトで小文字にできる（もう一度押すと大文字に戻る）
                autoCapOff.toggle()
            } else {
                shiftState = shiftState == .off ? .on : .off
            }
            lastShiftTap = now
            updateShiftDisplay()
        case .layer(let m):
            setMode(m)
            saveLastMode()
        case .widthToggle:
            // パソコンの全角／半角キーと同じ：日本語（ローマ字かな）⇄英字
            commitAll()
            japanese.toggle()
            shiftState = .off
            updateKeyLabels()
            // 続けて2回タップしたら、絵文字を開く（1回目の切り替えは元に戻す）
            let now = Date()
            if now.timeIntervalSince(lastWidthTap) < 0.4 {
                lastWidthTap = .distantPast
                japanese.toggle()
                updateKeyLabels()
                showEmoji()
            } else {
                lastWidthTap = now
            }
            saveLastMode()
        case .splitKeys:
            setSplit(true)
        case .cursorRight:
            cursorDrag(1)
        case .undoCommit:
            undoCommit()
        case .paste:
            // 英字面の貼付キーは、クリップボード履歴を開く
            commitAll()
            composer.clearPredictions()
            showClipboard()
        case .numberPad:
            break
        case .gripSwitch:
            commitAll()
            hideTop()
            hidePanel()
            model.toggleGrip()
        case .delete:
            if dir == .left {
                deleteLine()
            } else if dir == .up {
                deleteWord()
            } else if composer.isEmpty {
                composer.clearPredictions()
                if let sel = proxy.selectedText, !sel.isEmpty {
                    // 選択中（Safari のアドレス欄の補完など）は、選択だけを消す。deleteBackward だと補完の文字に加えて1文字余分に消えたため、置き換えで消す
                    proxy.insertText("")
                } else {
                    proxy.deleteBackward()
                }
                refreshBar()
            } else {
                composer.deleteBackward()
                updateComposition()
            }
        case .space:
            if composer.isEmpty {
                composer.clearPredictions()
                proxy.insertText(mode == .kana || japanese ? "　" : " ")
                refreshBar()
            } else {
                composer.selectNext()
                updateComposition()
            }
        case .newline:
            if composer.isEmpty {
                composer.clearPredictions()
                proxy.insertText("\n")
                refreshBar()
            } else {
                commitAll()
            }
        case .modeSwitch:
            setMode(mode.next)
            saveLastMode()
        case .settings:
            toggleSettings()
        case .nextKeyboard:
            // 地球儀：タップでキーボードを切り替え、上で設定、右でクリップボード、下で定型文（絵文字は英字の「A／あ」キーのダブルタップ）
            switch dir {
            case .up: toggleSettings()
            case .left: return
            case .right: showClipboard()
            case .down: showPhrases()
            default:
                commitAll()
                advanceToNextInputMode()
            }
        }
    }

    private var lastWidthTap = Date.distantPast

    private func toggleSettings() {
        if topHost != nil { hideTop() }
        else if panelHost != nil { hidePanel() }
        else { showSettings() }
    }

    // MARK: - 英字の大文字・全角

    private enum ShiftState { case off, on, locked }
    private var shiftState: ShiftState = .off
    private var lastShiftTap = Date.distantPast
    /// 文頭などで自動的に大文字になるところを、シフトで小文字に打ち消しているか
    private var autoCapOff = false
    /// 英字キーボードで日本語を打つ（ローマ字でかなにして変換する）
    private var japanese = false

    private func updateShiftDisplay() {
        keyboardView.uppercase = shiftState != .off || (mode == .qwerty && !autoCapOff && shouldAutoCapitalize())
        keyboardView.capsLock = shiftState == .locked
    }

    /// 英字・記号の面で入れる文字を、大文字・全角に直す
    private func styled(_ s: String) -> String {
        var out = s
        if mode == .qwerty, s.count == 1, let c = s.first, c.isLetter, c.isASCII {
            if shiftState != .off || (!autoCapOff && shouldAutoCapitalize()) { out = s.uppercased() }
            if shiftState == .on { shiftState = .off }
            autoCapOff = false
        }
        return out
    }

    // MARK: - 続けてタップで切り替え（トグル入力）

    private struct ToggleState {
        let def: KeyDef
        var index: Int
        var time: Date
        /// 直前に入れた文字（大文字にした場合も含め、入力欄と照らし合わせる）
        var output: String
    }
    private var toggle: ToggleState?

    /// 直前に入れた文字を、同じキーの次（step = -1 なら前）の文字に置き換える
    @discardableResult
    private func applyToggle(_ def: KeyDef, _ chars: [String], step: Int) -> Bool {
        guard var t = toggle else { return false }
        let cycle = chars.filter { !$0.isEmpty }
        guard cycle.count > 1 else { return false }
        let i = ((t.index + step) % cycle.count + cycle.count) % cycle.count
        var next = cycle[i]
        let prev = t.output
        if let p = prev.first, p.isUppercase, p.isASCII { next = next.uppercased() }
        let proxy = textDocumentProxy

        if !composer.isEmpty, composer.reading.hasSuffix(prev) {
            _ = composer.replaceLast(with: next)
            updateComposition()
        } else if composer.isEmpty, proxy.documentContextBeforeInput?.hasSuffix(prev) == true {
            proxy.deleteBackward()
            if case .kana = def.action, !isPunctuation(next) {
                composer.clearPredictions()
                composer.insert(next)
                updateComposition()
            } else {
                proxy.insertText(next)
                refreshBar()
            }
        } else {
            toggle = nil
            return false
        }
        t.index = i
        t.time = Date()
        t.output = next
        toggle = t
        return true
    }

    private var composingLocked: Bool { model.settings.lockWhileComposing && !composer.isEmpty }

    /// 入力欄が数字用のキーボードを求めているか
    private var isNumericField: Bool {
        switch textDocumentProxy.keyboardType ?? .default {
        case .numberPad, .phonePad, .decimalPad, .numbersAndPunctuation, .namePhonePad, .asciiCapableNumberPad: return true
        default: return false
        }
    }

    /// 変換待ちの間に止めるキー：入力を中断してしまう、ABC・片手／両手・設定・記号面・貼り付けなどのキー。
    /// かな・数字・⌫・空白（次候補）・改行（確定）・小゛゜など、読みを打ち続けるキーは止めない。
    /// 地球儀は止めない：タップの処理側が「確定してから切り替え」になっていて安全なため（v0.37.31）。
    /// ただし地球儀のフリック（設定・履歴・定型文）は変換中は handle 側で止める
    private func isAllowedWhileComposing(_ def: KeyDef) -> Bool {
        switch def.action {
        case .modeSwitch, .gripSwitch, .settings, .layer, .paste, .widthToggle, .splitKeys: return false
        default: return true
        }
    }

    private func isLetterKey(_ def: KeyDef) -> Bool {
        guard def.id.hasPrefix("q_"), let c = def.label.first else { return false }
        return c.isLetter && c.isASCII
    }

    /// 英字の面で、入力欄の設定に合わせて文頭などを大文字にするか
    private func shouldAutoCapitalize() -> Bool {
        guard mode == .qwerty, !japanese else { return false }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        switch textDocumentProxy.autocapitalizationType ?? .none {
        case .allCharacters:
            return true
        case .words:
            return before.isEmpty || before.last!.isWhitespace
        case .sentences:
            if before.isEmpty || before.last == "\n" { return true }
            guard before.last!.isWhitespace else { return false }
            let t = before.trimmingCharacters(in: .whitespaces)
            return t.isEmpty || [".", "!", "?", "\n"].contains(t.last!)
        default:
            return false
        }
    }

    private func pick(_ chars: [String], _ dir: FlickDirection) -> String {
        let c = chars[dir.rawValue]
        return c.isEmpty ? chars[0] : c
    }

    private func isPunctuation(_ s: String) -> Bool {
        ["、", "。", "？", "！", "「", "」"].contains(s)
    }

    /// ⌫の左フリック：入力中なら全部消す。そうでなければ直前の語（同じ種類の文字が続く部分）を消す
    private func deleteWord() {
        if !composer.isEmpty {
            composer.reset()
            updateComposition()
            return
        }
        composer.clearPredictions()
        let proxy = textDocumentProxy
        guard let before = proxy.documentContextBeforeInput, let last = before.last else { refreshBar(); return }
        let count: Int
        if last.isWhitespace || last.isNewline {
            count = before.reversed().prefix { $0.isWhitespace || $0.isNewline }.count
        } else {
            let kind = charKind(last)
            count = before.reversed().prefix { charKind($0) == kind }.count
        }
        for _ in 0..<max(1, count) { proxy.deleteBackward() }
        refreshBar()
    }

    /// ⌫の左フリック：入力中なら全部消す。そうでなければ、いまの行の、カーソルより前を消す
    private func deleteLine() {
        if !composer.isEmpty {
            composer.reset()
            updateComposition()
            return
        }
        composer.clearPredictions()
        let proxy = textDocumentProxy
        guard let before = proxy.documentContextBeforeInput, !before.isEmpty else { refreshBar(); return }
        let line = before.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        // 行の先頭にいるときは、前の行との改行を消す
        let text = line.isEmpty ? "\n" : line
        for _ in 0..<text.count { proxy.deleteBackward() }
        refreshBar()
    }

    private func charKind(_ c: Character) -> Int {
        guard let u = c.unicodeScalars.first?.value else { return 0 }
        switch u {
        case 0x3041...0x309F: return 1          // ひらがな
        case 0x30A0...0x30FF: return 2          // カタカナ
        case 0x4E00...0x9FFF, 0x3005: return 3  // 漢字
        default:
            if c.isLetter || c.isNumber { return 4 }   // 英数字
            if c.isWhitespace || c.isNewline { return 5 }
            return 6                                   // 記号
        }
    }

    /// ↺：直前の確定を取り消して、読みに戻す
    private func undoCommit() {
        if !composer.isEmpty {
            if composer.selectedIndex != nil {
                composer.deleteBackward()   // 候補の選択を解除してひらがなに戻す
                updateComposition()
            }
            return
        }
        let proxy = textDocumentProxy
        // 文字を選択しているときは、選んだ文字を読みに戻して、変換し直す
        if let sel = proxy.selectedText, !sel.isEmpty, sel.count <= 40, let reading = reconversionReading(sel) {
            proxy.deleteBackward()   // 選択している文字が消える
            lastCommit = nil
            composer.clearPredictions()
            composer.restore(reading: reading)
            updateComposition()
            return
        }
        guard let last = lastCommit, let before = proxy.documentContextBeforeInput,
              before.hasSuffix(last.text) else { return }
        for _ in 0..<last.text.count { proxy.deleteBackward() }
        lastCommit = nil
        composer.restore(reading: last.reading)
        updateComposition()
    }

    /// 再変換できる読み：ひらがな・カタカナだけならそのまま（ひらがなにする）。漢字まじりは、以前このキーボードで選んだ語だけ
    private func reconversionReading(_ text: String) -> String? {
        let hira = text.applyingTransform(.hiraganaToKatakana, reverse: true) ?? text
        if Composer.isHiragana(hira) { return hira }
        return composer.readingChosen(for: text)
    }

    /// 空白キー長押しの左右：入力中なら文節の区切りを動かし、そうでなければカーソルを動かす
    /// 空白キーを長押しして動かさずに離したとき：変換中なら、ひらがなのまま見せる（改行で確定）
    private func spaceHold() {
        guard register == nil, !composer.isEmpty else { return }
        composer.showReadingOnly()
        updateComposition()
    }

    private func cursorDrag(_ steps: Int) {
        if register != nil { return }
        if !composer.isEmpty {
            composer.moveSegment(by: steps)
            updateComposition()
        } else {
            composer.clearPredictions()
            textDocumentProxy.adjustTextPosition(byCharacterOffset: steps)
            refreshBar()
        }
    }

    /// 上下の行へ移動する。改行で区切られた行が対象（折り返しは iOS から位置が分からないため対象外）。
    /// 移動先は前または次の行の頭。いまのカーソルが行末にあるときだけ、前または次の行の末
    private func moveCursorVertically(_ lines: Int) {
        guard composer.isEmpty, register == nil else { return }
        composer.clearPredictions()
        refreshBar()
        let proxy = textDocumentProxy
        // adjustTextPosition は反応が遅れるので、何行ぶんでも手元の文字で位置を計算し、最後に1回だけ動かす
        let all = Array((proxy.documentContextBeforeInput ?? "") + (proxy.documentContextAfterInput ?? ""))
        var pos = (proxy.documentContextBeforeInput ?? "").count
        let startPos = pos
        func lineStart(_ i: Int) -> Int {
            var k = i
            while k > 0, all[k - 1] != "\n" { k -= 1 }
            return k
        }
        func lineEnd(_ i: Int) -> Int {
            var k = i
            while k < all.count, all[k] != "\n" { k += 1 }
            return k
        }
        var atEnd = pos >= all.count || all[pos] == "\n"
        for _ in 0..<abs(lines) {
            if lines < 0 {
                let ls = lineStart(pos)
                if ls == 0 { pos = 0; break }   // いちばん上の行：文頭へ
                let prevEnd = ls - 1
                pos = atEnd ? prevEnd : lineStart(prevEnd)
            } else {
                let le = lineEnd(pos)
                if le >= all.count { pos = all.count; break }   // いちばん下の行：文末へ
                let nextStart = le + 1
                pos = atEnd ? lineEnd(nextStart) : nextStart
            }
        }
        if pos != startPos { proxy.adjustTextPosition(byCharacterOffset: pos - startPos) }
    }

    // MARK: - 入力欄への反映（本家 azooKey と同じく、確定は insertText で下線付きの文字を置き換える）

    /// 入力欄に下線付きの文字があるか
    private var markedActive = false

    /// いま入力欄に出している下線付きの文字（ライブ変換で、変わったときだけ入れ替えるため）
    private var shownMarked = ""
    private func showMarked(_ text: String, highlight: NSRange? = nil) {
        shownMarked = text
        textDocumentProxy.setMarkedText(text, selectedRange: highlight ?? NSRange(location: (text as NSString).length, length: 0))
        markedActive = true
        // この入力欄が、下線付きの文字を文脈として返すか確かめておく（空になったかどうかの判断に使う）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.markedActive, !self.composer.isEmpty else { return }
            let p = self.textDocumentProxy
            // 文脈が空でも、hasText で下線付きの文字を数えるアプリがある（LINE など）
            if !(p.documentContextBeforeInput ?? "").isEmpty || p.hasText {
                self.markedVisible = true
                self.scheduleEmptyCheck(after: 0.6)
            }
        }
    }
    private var markedVisible = false

    /// 下線付きの文字を消す（入力中の文字を全部消したとき）
    private func clearMarked() {
        guard markedActive else { return }
        textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        textDocumentProxy.unmarkText()
        markedActive = false
    }

    /// 下線付きの文字を、確定した文字で置き換える
    private func insertCommitted(_ text: String) {
        textDocumentProxy.insertText(text)
        markedActive = false
        // 括弧の対だけを確定したときは、中にカーソルを置く（続きの変換が残っているときは動かさない）
        cursorInsidePair = false
        if composer.isEmpty, text.count == 2, Self.pairTexts.contains(text) {
            textDocumentProxy.adjustTextPosition(byCharacterOffset: -1)
            cursorInsidePair = true
        }
        // この入力欄が文脈を返せるか確かめておく（返せないアプリでは、空になったかどうかを判断しない）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let p = self.textDocumentProxy
            if !(p.documentContextBeforeInput ?? "").isEmpty || !(p.documentContextAfterInput ?? "").isEmpty {
                self.contextSeen = true
            }
        }
    }

    /// 入力欄の下線付きの文字と、変換候補の帯を更新する
    private func updateComposition() {
        composer.typoCorrection = model.settings.typoCorrection
        composer.liveConversion = model.settings.liveConversion
        composer.zenzai = model.settings.zenzai
        composer.zenzaiHigh = model.settings.zenzaiHigh
        updateLeftContext()
        hideCandidateList()
        if composer.isEmpty {
            clearMarked()
        } else if soloRemainder != nil {
            // 範囲だけを変換中で残している間は、入力欄には範囲だけを出す
            let t = composer.rangeMarkedText
            showMarked(t, highlight: NSRange(location: 0, length: (t as NSString).length))
        } else {
            showMarked(composer.markedText, highlight: composer.markedHighlight)
        }
        refreshBar()
        scheduleCandidates()
    }

    /// 確定の文字を先に入れてから、次の予測を計算する
    private func schedulePredictions() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.composer.loadPredictionsIfNeeded()
            if self.composer.isEmpty { self.refreshBar() }
        }
    }

    /// 打鍵が続いている間は変換を待ち、指が止まったらまとめて変換する
    private var candidateWork: DispatchWorkItem?
    /// Zenzai に渡す、カーソルより前の文章（入力中の下線の文字は除く）
    private func updateLeftContext() {
        guard model.settings.zenzai else { composer.leftContext = ""; return }
        var before = textDocumentProxy.documentContextBeforeInput ?? ""
        if markedActive, !shownMarked.isEmpty, before.hasSuffix(shownMarked) { before.removeLast(shownMarked.count) }
        composer.leftContext = String(before.suffix(20))
    }

    private func scheduleCandidates() {
        candidateWork?.cancel()
        guard composer.needsRefresh else { return }
        composer.zenzai = model.settings.zenzai
        composer.zenzaiHigh = model.settings.zenzaiHigh
        updateLeftContext()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.composer.refreshIfNeeded()
            self.refreshBar()
            // ライブ変換：変換が済んだら、入力欄の下線の文字を変換した形に入れ替える
            if self.model.settings.liveConversion, !self.composer.isEmpty, self.markedActive {
                let t = self.composer.markedText
                if t != self.shownMarked { self.showMarked(t, highlight: self.composer.markedHighlight) }
            }
        }
        candidateWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// 入力中は変換候補、確定直後は予測、それ以外は何も出さない
    private func refreshBar() {
        // 範囲選択の入り・出で、読みラベルの余白が要るかどうかが変わる
        if composer.rangeMode != lastRangeMode {
            lastRangeMode = composer.rangeMode
            updateBarHeight()
        }
        updateKeyLabels()
        if !composer.isEmpty {
            pasteChip = false
            imageChip = false
            showBar(composer.candidateTexts, selected: composer.selectedIndex)
        } else {
            pasteChip = false
            imageChip = false
            englishWords = domainCandidates.isEmpty ? currentEnglishCompletions() : []
            if !englishWords.isEmpty {
                showBar(englishWords, selected: nil)
            } else {
                let items = domainCandidates.isEmpty ? composer.predictionTexts : domainCandidates
                // 出す候補がなく、クリップボードに文字があるときは、貼り付けを出す
                let canPaste = items.isEmpty && hasFullAccess
                pasteChip = canPaste && UIPasteboard.general.hasStrings
                // 画像はキーボードから入れられないので、入力欄を長押しして貼り付けてもらう
                imageChip = canPaste && !pasteChip && UIPasteboard.general.hasImages
                showBar(pasteChip ? ["コピー内容の貼り付け"] : (imageChip ? ["長押しして画像を貼り付け"] : items), selected: nil,
                        dimmed: pasteChip || imageChip)
            }
            hideCandidateList()
        }
        let canExpand = !composer.isEmpty && !composer.candidateTexts.isEmpty
        if !canExpand { hideCandidateList() }
        candidateBar.setExpand(visible: canExpand, expanded: isCandidateListOpen)
    }

    /// 改行キー・空白キーの表示をiOS標準に合わせる（入力中は「確定」「次候補」）
    private func updateKeyLabels() {
        let proxy = textDocumentProxy
        var labels: [String: String] = [:]
        var accent: Set<String> = []
        var disabled: Set<String> = []
        if !composer.isEmpty {
            labels["newline"] = "確定"
            accent.insert("newline")
            if mode == .kana { labels["space"] = "次候補" }
        } else {
            let type = proxy.returnKeyType ?? .default
            let name: String
            switch type {
            case .go: name = "開く"
            case .google, .yahoo, .search: name = "検索"
            case .join: name = "参加"
            case .next: name = "次へ"
            case .route: name = "経路"
            case .send: name = "送信"
            case .done: name = "完了"
            case .emergencyCall: name = "緊急"
            case .continue: name = "続ける"
            default: name = "改行"
            }
            labels["newline"] = name
            if type != .default { accent.insert("newline") }
            if proxy.enablesReturnKeyAutomatically == true, !proxy.hasText {
                disabled.insert("newline")
            }
        }
        if composingLocked {
            for k in keyboardView.keys where !isAllowedWhileComposing(k.def) { disabled.insert(k.def.id) }
        }
        labels["width"] = japanese ? "あ" : "A"
        labels["qpunct"] = japanese ? "、。?!" : ",.?!"
        if mode != .kana { labels["space"] = composer.isEmpty ? (japanese ? "空白" : "space") : "次候補" }
        keyboardView.labelOverrides = labels
        keyboardView.accentIDs = accent
        keyboardView.disabledIDs = disabled
        updateShiftDisplay()
    }

    // MARK: - 候補の一覧

    private func toggleCandidateList() {
        if isCandidateListOpen { closeCandidateList(); return }
        composer.refreshIfNeeded()
        candidateListView.setItems(Array(composer.listTexts.prefix(120)))
        openCandidateList()
    }

    private func openCandidateList() {
        guard !isCandidateListOpen else { return }
        isCandidateListOpen = true
        candidateListView.isHidden = false
        // フェードは残すが、タップはフェード中も通す。
        candidateListView.alpha = 0
        candidateListView.transform = CGAffineTransform(translationX: 0, y: -24)
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .allowUserInteraction], animations: {
            self.candidateListView.alpha = 1
            self.candidateListView.transform = .identity
        }, completion: nil)
        // 一覧を開いている間は、キーが透けて文字と重ならないよう、キーを隠す
        keyboardView.isHidden = true
        middleHost?.view.isHidden = true
        setMiddleGrabberVisible(false)
        updateFanDockButton()
        candidateBar.setExpand(visible: true, expanded: true)
    }

    /// 一覧を閉じる。状態はすぐ切り替え、見た目だけフェードする。
    /// フェード中でも次のタップが通るよう、.allowUserInteraction を付ける。
    /// 閉じるだけのときは帯の再計算を呼ばない（再計算が重さの原因だったため）。
    private func closeCandidateList() {
        guard isCandidateListOpen else { return }
        // まずスクロールを止める。減速中のまま閉じると、閉じるタップが
        // スクロール停止に消費されたり、フェード中に一覧が動き続けたりする。
        candidateListView.stopScrolling()
        candidateBar.stopScrolling()
        isCandidateListOpen = false
        // キーはすぐ復帰させる。見た目だけフェードする。
        keyboardView.isHidden = false
        keyboardView.alpha = 0
        middleHost?.view.isHidden = false
        middleHost?.view.alpha = 0
        if lastPanelRect != nil { setMiddleGrabberVisible(true) }
        updateFanDockButton()
        let canExpand = !composer.isEmpty && !composer.candidateTexts.isEmpty
        candidateBar.setExpand(visible: canExpand, expanded: false)
        UIView.animate(withDuration: 0.14, delay: 0, options: [.curveEaseIn, .allowUserInteraction], animations: {
            self.candidateListView.alpha = 0
            self.candidateListView.transform = CGAffineTransform(translationX: 0, y: -24)
        }, completion: { _ in
            // フェード中に開き直されていたら、隠さない。
            guard !self.isCandidateListOpen else { return }
            self.candidateListView.isHidden = true
            self.candidateListView.alpha = 1
            self.candidateListView.transform = .identity
        })
        UIView.animate(withDuration: 0.12, delay: 0, options: [.allowUserInteraction], animations: {
            self.keyboardView.alpha = 1
            self.middleHost?.view.alpha = 1
        }, completion: nil)
    }

    private func hideCandidateList() {
        closeCandidateList()
    }

    /// 一覧から選んだとき。状態とキーの復帰を先に済ませてから確定する。
    /// 確定の文字入れや帯の更新を、アニメーション完了待ちにしない。
    private func selectFromCandidateList(_ index: Int) {
        closeCandidateList()
        commitCandidate(index)
    }

    /// 「@」のあとに出す、よく使うメールのドメイン
    private var domainCandidates: [String] = []
    /// 括弧を対で入れた直後の、閉じ括弧
    private var pairClose: String?
    private static let bracketPairs = ["(": ")", "[": "]", "{": "}"]
    /// 変換候補として出る括弧の対（確定したら中にカーソルを置く）
    private static let pairTexts: Set<String> = [
        "()", "[]", "{}", "<>", "（）", "［］", "｛｝", "＜＞", "「」", "『』", "【】", "〔〕", "〈〉", "《》", "“”", "‘’", "\"\"", "''"
    ]
    private var cursorInsidePair = false
    private static let mailDomains = [
        "gmail.com", "icloud.com", "yahoo.co.jp", "outlook.jp", "outlook.com", "docomo.ne.jp",
        "ezweb.ne.jp", "au.com", "softbank.ne.jp", "i.softbank.jp", "hotmail.co.jp", "hotmail.com",
        "yahoo.com", "live.jp", "nifty.com", "ybb.ne.jp"
    ]

    // MARK: - 真ん中の候補の一覧（iOS標準の配置）

    private var splitFromOne = false

    /// かなの分割をオン・オフする（ピンチと、分割のキーから）。片手持ちからは両手持ちに切り替えて分割する
    private func setSplit(_ split: Bool) {
        if split, model.grip == .one {
            commitAll()
            model.toggleGrip()
            splitFromOne = true
        }
        guard model.grip == .two, model.settings.splitKana != split else { return }
        model.settings.splitKana = split
        // 片手持ちから分割したときは、ピンチインで片手持ちに戻す
        if !split, splitFromOne {
            splitFromOne = false
            commitAll()
            model.toggleGrip()
        }
    }
    private let panelModel = PanelModel()
    private var middleHost: UIHostingController<MiddlePanel>?

    private func showBar(_ items: [String], selected: Int?, dimmed: Bool = false) {
        let reading = composer.isEmpty ? nil : composer.readingLabel
        candidateBar.show(items, selected: selected, dimmed: dimmed, reading: reading)
        // 真ん中のエリアは、内容が変わったときだけ更新する。
        // 毎回代入すると @Published が再描画を誘発し、予測が出た直後の
        // フリックと重なって重くなるため。
        let panelItems = Array((composer.isEmpty ? items : composer.listTexts).prefix(60))
        if panelModel.items != panelItems { panelModel.items = panelItems }
        if panelModel.selected != selected { panelModel.selected = selected }
        let readingText = reading ?? ""
        if panelModel.reading != readingText { panelModel.reading = readingText }
    }

    /// 扇形のとき、端にうっすら出す「寄せる側を変える」ボタン
    private var fanDockButton: UIButton?

    /// 扇形の寄せボタンの表示と位置を、いまの状態に合わせる
    private func updateFanDockButton() {
        let s = model.settings
        let show = mode == .kana && model.grip == .one && s.shape == .fan
            && !KeyboardLayout.usesIOS(s, mode, model.grip, view.bounds.width)
            && !isCandidateListOpen && topHost == nil && panelHost == nil
        guard show else { fanDockButton?.isHidden = true; return }
        if fanDockButton == nil {
            let b = UIButton(type: .system)
            b.tintColor = UIColor.white.withAlphaComponent(0.35)
            b.addTarget(self, action: #selector(fanDockTapped), for: .touchUpInside)
            view.addSubview(b)
            fanDockButton = b
        }
        guard let b = fanDockButton else { return }
        b.isHidden = false
        // いま寄っている側と反対の端に、行き先の向きの矢印を出す。
        // 寄っている側の判定は、レイアウト側と同じ関数を使う（ずれないように）
        let dockedLeft = KeyboardLayout.isLeftHand(s)
        b.setImage(UIImage(systemName: dockedLeft ? "chevron.right" : "chevron.left"), for: .normal)
        let w: CGFloat = 30, h: CGFloat = 72
        b.frame = CGRect(x: dockedLeft ? view.bounds.width - w : 0,
                         y: (view.bounds.height - h) / 2 + 16, width: w, height: h)
        view.bringSubviewToFront(b)
    }

    @objc private func fanDockTapped() {
        var s = model.settings
        s.fanDockFlip.toggle()
        model.settings = s
    }

    /// 真ん中の候補パネルを出す範囲（レイアウトのたびに合わせ直すために覚えておく）
    private var lastPanelRect: CGRect?

    /// 真ん中の配置のとき、キーボード上端の真ん中に出すつまみ。
    /// 通常の配置で候補の帯のつまみを下に引いて閉じるのと同じ場所・同じ操作にする。
    /// パネルの外（キーボード側）に置くので、下への引きがパネル内の一覧のスクロールに取られない
    private var middleGrabber: UIView?

    private func setMiddleGrabberVisible(_ visible: Bool) {
        if visible {
            if middleGrabber == nil {
                let v = UIView()
                v.backgroundColor = .clear
                let pill = UIView()
                pill.backgroundColor = UIColor.systemGray.withAlphaComponent(0.55)
                pill.layer.cornerRadius = 2.5
                pill.frame = CGRect(x: 62, y: 10.5, width: 36, height: 5)
                pill.isUserInteractionEnabled = false
                v.addSubview(pill)
                v.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(middleGrabberPanned(_:))))
                view.addSubview(v)
                middleGrabber = v
            }
            middleGrabber?.isHidden = false
            layoutMiddleGrabber()
            if let v = middleGrabber { view.bringSubviewToFront(v) }
        } else {
            middleGrabber?.isHidden = true
        }
    }

    private func layoutMiddleGrabber() {
        guard let v = middleGrabber, view.bounds.width > 0 else { return }
        v.frame = CGRect(x: (view.bounds.width - 160) / 2, y: 2, width: 160, height: 26)
    }

    @objc private func middleGrabberPanned(_ g: UIPanGestureRecognizer) {
        guard g.state == .ended else { return }
        let t = g.translation(in: view)
        if t.y > 24, abs(t.x) < t.y / 1.5 {
            commitAll()
            dismissKeyboard()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 外側→内側など画面が切り替わった直後は、パネルの位置が古いまま残って
        // ⌫などのキーを覆うことがあるので、覚えている範囲に合わせ直す
        if let rect = lastPanelRect, let host = middleHost, host.view.frame != rect {
            host.view.frame = rect
            view.bringSubviewToFront(host.view)
        }
        layoutMiddleGrabber()
        if let v = middleGrabber, !v.isHidden { view.bringSubviewToFront(v) }
        updateFanDockButton()
    }

    private func updateMiddlePanel(_ rect: CGRect?) {
        lastPanelRect = rect
        // 真ん中に候補を出すときは、上の候補の帯は要らない
        candidateBar.isHidden = rect != nil || panelHost != nil
        guard let rect else {
            setMiddleGrabberVisible(false)
            if let h = middleHost {
                h.willMove(toParent: nil); h.view.removeFromSuperview(); h.removeFromParent()
                middleHost = nil
            }
            return
        }
        setMiddleGrabberVisible(!isCandidateListOpen)
        if middleHost == nil {
            let host = UIHostingController(rootView: MiddlePanel(model: panelModel, onSelect: { [weak self] i in
                guard let self else { return }
                // 長押しが成立した項目の、その直後の通常選択は飲み込む
                if self.panelModel.suppressSelect == i { self.panelModel.suppressSelect = nil; return }
                self.selectFromBar(i)
            }, onSwipeDown: { [weak self] in
                // 真ん中を下にフリックしたら、入力中の文字を確定してキーボードを閉じる
                self?.commitAll()
                self?.dismissKeyboard()
            }, onReading: { [weak self] in self?.commitReadingAsIs() },
               onRangeEnter: { [weak self] i in self?.rangePressBegan(i) },
               onRangeDrag: { [weak self] dx in self?.rangePressDragged(dx) },
               onRangeEnded: { [weak self] in self?.rangePressEnded() }))
            host.view.backgroundColor = .clear
            addChild(host)
            view.addSubview(host.view)
            host.didMove(toParent: self)
            middleHost = host
        }
        middleHost?.view.frame = rect
        if let v = middleHost?.view { view.bringSubviewToFront(v) }
    }

    /// 英字の予測変換（iOS標準の英単語補完）。打ちかけの単語の候補
    private var englishWords: [String] = []
    private let textChecker = UITextChecker()
    private static let wordTail = try? NSRegularExpression(pattern: "[A-Za-z']+$")

    private func partialEnglishWord() -> String? {
        guard mode == .qwerty, !japanese, let before = textDocumentProxy.documentContextBeforeInput,
              let re = Self.wordTail else { return nil }
        let ns = before as NSString
        guard let m = re.firstMatch(in: before, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range)
    }

    private func currentEnglishCompletions() -> [String] {
        guard let word = partialEnglishWord() else { return [] }
        let range = NSRange(location: 0, length: (word as NSString).length)
        let list = textChecker.completions(forPartialWordRange: range, in: word, language: "en_US") ?? []
        return Array(list.filter { $0.lowercased() != word.lowercased() }.prefix(12))
    }

    /// 候補の帯に「貼り付け」を出しているか
    private var pasteChip = false
    private var imageChip = false

    /// 「コピー内容の貼り付け」を押したとき。他アプリでコピーした文字は、
    /// 初回の読み取りが承認待ちで空になることがあるので、少し置いて読み直す
    private func pasteFromChip(attempt: Int) {
        if let text = UIPasteboard.general.string, !text.isEmpty {
            composer.clearPredictions()
            textDocumentProxy.insertText(text)
            lastCommit = nil
            refreshBar()
            return
        }
        if attempt < 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.pasteChip, self.composer.isEmpty else { return }
                self.pasteFromChip(attempt: attempt + 1)
            }
        } else {
            refreshBar()
        }
    }

    private func selectFromBar(_ index: Int) {
        if imageChip, composer.isEmpty { return }
        if pasteChip, composer.isEmpty {
            pasteFromChip(attempt: 0)
            return
        }
        if composer.isEmpty, domainCandidates.isEmpty, !englishWords.isEmpty, index < englishWords.count,
           let word = partialEnglishWord() {
            // 打ちかけの単語を、選んだ単語に置き換えて空白を入れる
            for _ in 0..<word.count { textDocumentProxy.deleteBackward() }
            textDocumentProxy.insertText(englishWords[index] + " ")
            englishWords = []
            lastCommit = nil
            refreshBar()
            updateShiftDisplay()
            return
        }
        if !composer.isEmpty {
            if composer.rangeMode {
                // 範囲選択中は、帯の番号は範囲だけの候補の番号。そのまま渡す
                commitCandidate(index)
            } else if composer.needsRefresh {
                candidateWork?.cancel()
                guard let fresh = composer.freshIndex(forStale: index) else { refreshBar(); return }
                commitCandidate(fresh)
            } else {
                commitCandidate(index)
            }
        } else if !domainCandidates.isEmpty {
            if index < domainCandidates.count { textDocumentProxy.insertText(domainCandidates[index]) }
            domainCandidates = []
            lastCommit = nil
            refreshBar()
        } else if let text = composer.choosePrediction(at: index) {
            textDocumentProxy.insertText(text)
            lastCommit = nil
            refreshBar()
            schedulePredictions()
        }
    }

    /// 範囲選択を始めたときの範囲の長さ（ドラッグの移動量を文字数に変えるための起点）
    private var rangeStartLength = 0
    /// 前回の範囲選択の状態（帯の高さを切り替えるため）
    private var lastRangeMode = false

    /// 候補の長押し：範囲選択に入る。最初の範囲は、その候補の先頭の文節
    private func rangePressBegan(_ index: Int) {
        // パネル側の長押しで付いた選択抑制が、選択として届かなかった場合の後始末
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            if self?.panelModel.suppressSelect == index { self?.panelModel.suppressSelect = nil }
        }
        guard !composer.isEmpty, composer.focusClause == nil else { return }
        var index = index
        if composer.needsRefresh {
            candidateWork?.cancel()
            guard let fresh = composer.freshIndex(forStale: index) else { refreshBar(); return }
            index = fresh
        }
        guard composer.enterRangeMode(candidateAt: index) else {
            traceRange("長押し: 範囲に入れなかった（候補番号=\(index) 空=\(composer.isEmpty) 文節選択中=\(composer.focusClause != nil)）")
            return
        }
        traceRange("長押し: 範囲に入った（全体=\(composer.rangeLength)文字）")
        rangeStartLength = composer.rangeLength
        updateComposition()
    }

    /// 範囲選択のドラッグ：横の移動量ぶん、範囲を伸縮する。
    /// ドラッグ中は帯を作り直さず、入力欄の選択表示だけを動かす（指を離したときに帯を出し直す）
    private func rangePressDragged(_ dx: CGFloat) {
        guard composer.rangeMode else { return }
        // カーソル移動と同じく、2.2mmで1文字ぶん
        let steps = Int((dx / (2.2 * CGFloat(KeyboardSettings.ptPerMM))).rounded())
        if composer.setRangeLength(rangeStartLength + steps) {
            traceRange("ドラッグ: 範囲=\(composer.rangeLength)文字")
            showMarked(composer.markedText, highlight: composer.markedHighlight)
            // どこまでが変換対象か、帯とパネルの読みラベルでも見せる
            candidateBar.setReadingLabel(composer.readingLabel)
            let rt = composer.readingLabel ?? ""
            if panelModel.reading != rt { panelModel.reading = rt }
        }
    }

    /// 範囲だけを変換中で残している間、範囲の後ろに未変換で確定してある読み
    private var soloRemainder: String?

    /// 範囲選択の一連の動きの記録（切り分け用。「変換の診断」の末尾に出す）。
    /// v0.37.30: メモリだけだとキーボードのプロセスが再起動したときに消えるので、共有の保存先に残す
    private static let rangeTraceKey = "DuoFlick.rangeTrace"
    private func traceRange(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        var lines = SharedStore.defaults.stringArray(forKey: Self.rangeTraceKey) ?? []
        lines.append("\(f.string(from: Date())) \(s)")
        if lines.count > 40 { lines.removeFirst(lines.count - 40) }
        SharedStore.defaults.set(lines, forKey: Self.rangeTraceKey)
    }
    private var savedRangeTrace: [String] {
        SharedStore.defaults.stringArray(forKey: Self.rangeTraceKey) ?? []
    }
    private func proxyContext(_ proxy: UITextDocumentProxy) -> String {
        "前[\(proxy.documentContextBeforeInput ?? "nil")] 後[\(proxy.documentContextAfterInput ?? "nil")] hasText=\(proxy.hasText)"
    }

    /// 範囲選択の指を離した：範囲はそのままで、帯に範囲だけの候補を出す。
    /// 範囲の後ろは未変換のまま一度確定して文書に入れ、入力欄では範囲だけが変換中（下線）で残るようにする
    private func rangePressEnded() {
        guard composer.rangeMode else {
            traceRange("離す: 範囲モードでないため何もしない")
            return
        }
        updateComposition()
        // ライブ変換／Zenzai の設定に関わらず行う（v0.37.28 で条件を撤廃。今回の報告の原因ではない）
        let suffix = composer.rangeSuffixReading
        traceRange("離す: 範囲=\(composer.rangeLength)文字 後ろ=[\(suffix)] markedActive=\(markedActive)")
        guard !suffix.isEmpty else {
            traceRange("離す: 後ろが空なのでソロ化しない")
            return
        }
        let proxy = textDocumentProxy
        traceRange("掃除前: \(proxyContext(proxy))")
        clearMarked()
        traceRange("掃除後: \(proxyContext(proxy))")
        proxy.insertText(suffix)
        traceRange("後ろを挿入後: \(proxyContext(proxy))")
        proxy.adjustTextPosition(byCharacterOffset: -(suffix as NSString).length)
        traceRange("カーソルを戻した後: \(proxyContext(proxy))")
        soloRemainder = suffix
        let t = composer.rangeMarkedText
        showMarked(t, highlight: NSRange(location: 0, length: (t as NSString).length))
        traceRange("範囲だけ表示後: \(proxyContext(proxy))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.traceRange("離して0.6秒後: \(self.proxyContext(self.textDocumentProxy)) solo=\(self.soloRemainder != nil) 範囲モード=\(self.composer.rangeMode)")
        }
    }

    /// 範囲だけを変換中で残した状態を解く：確定してあった後ろの分を消し、読み全体の変換待ちに戻す
    private func cancelSoloRange() {
        guard let s = soloRemainder else { return }
        soloRemainder = nil
        clearMarked()
        let proxy = textDocumentProxy
        proxy.adjustTextPosition(byCharacterOffset: (s as NSString).length)
        for _ in 0..<s.count { proxy.deleteBackward() }
    }

    private func commitCandidate(_ index: Int) {
        // ライブ変換で文節を選び直している途中は、確定せず、その文節を入れ替える
        if composer.chooseClauseAlt(index) {
            updateComposition()
            return
        }
        let reading = composer.reading
        guard let text = composer.commit(candidateAt: index) else { return }
        keyboardView.resetFlickHistory()   // 予測・変換で選んだ文字は、打ったフリックと対応しないので、ずれ補正の対象にしない
        insertCommitted(text)
        // 範囲だけを変換中で残していた場合は、後ろに未変換で確定してあった分を文書から消し、
        // 続きとして変換待ちに戻す（composer 側は残りの読みを変換待ちとして持っている）
        if let s = soloRemainder {
            soloRemainder = nil
            traceRange("候補で確定: ソロ解除、後ろ[\(s)]を消して変換待ちに戻す")
            let proxy = textDocumentProxy
            proxy.adjustTextPosition(byCharacterOffset: (s as NSString).length)
            for _ in 0..<s.count { proxy.deleteBackward() }
        }
        if composer.isEmpty {
            lastCommit = cursorInsidePair ? nil : (text, reading)   // カーソルが括弧の中にあると取り消せないので覚えない
            refreshBar()
            schedulePredictions()
        } else {
            updateComposition()
        }
    }

    /// 帯の左端の読みを押したとき：ひらがなのまま確定する（文節を選び直している間は、その文節をひらがなにする）
    private func commitReadingAsIs() {
        let reading = composer.reading
        guard let text = composer.commitReadingAsIs() else {
            updateComposition()
            return
        }
        keyboardView.resetFlickHistory()
        insertCommitted(text)
        lastCommit = (text, reading)
        refreshBar()
        schedulePredictions()
    }

    private func commitAll() {
        guard !composer.isEmpty else { return }
        let reading = composer.reading
        let text = composer.commitAll()
        keyboardView.resetFlickHistory()
        insertCommitted(text)
        lastCommit = cursorInsidePair ? nil : (text, reading)
        refreshBar()
        schedulePredictions()
    }

    /// 句読点で確定する：今の内容を確定してから句読点を入れる（iOS標準の動き）。
    /// 候補を選んでいればその候補で確定し、選んでいなければ読みのまま確定する（composer.commitAll の判断に任せる）。
    /// 取り消し（⌫の下フリック）で戻せるよう、句読点も含めて lastCommit に覚える
    private func commitAndPunctuate(_ s: String) {
        guard !composer.isEmpty else { return }
        let reading = composer.reading
        let text = composer.commitAll()
        keyboardView.resetFlickHistory()
        insertCommitted(text)
        textDocumentProxy.insertText(s)
        lastCommit = cursorInsidePair ? nil : (text + s, reading)
        refreshBar()
        schedulePredictions()
    }

    // MARK: - 打ち比べで最適化

    private func startOptimizing() {
        commitAll()
        setMode(.kana)
        optimizer.start(model: model)
        optimizing = true
        let panel = OptimizerPanel(opt: optimizer) { [weak self] in self?.stopOptimizing() }
        showTop(UIHostingController(rootView: panel), height: 128)
    }

    private func stopOptimizing() {
        if optimizing { optimizer.finish() }
        optimizing = false
        hideTop()
    }

    // MARK: - 定型文・クリップボード

    private var panelHost: UIViewController?

    private func showPhrases() {
        let panel = TextListPanel(
            title: "定型文",
            store: phrases,
            emptyMessage: "定型文はまだありません。入力欄で文字を選択してから「選択した文字を追加」を押すか、クリップボードの履歴から追加できます。",
            notice: nil,
            addTitle: "選択した文字を追加",
            onAdd: { [weak self] in self?.addPhraseFromSelection() },
            secondaryTitle: nil,
            onSecondary: nil,
            onSelect: { [weak self] text in self?.insertFromPanel(text) },
            onClose: { [weak self] in self?.hidePanel() })
        showPanel(panel, hidesKeys: true)
    }

    private func showEmoji() {
        commitAll()
        let panel = EmojiPanel(
            onSelect: { [weak self] e in
                guard let self else { return }
                self.composer.clearPredictions()
                self.textDocumentProxy.insertText(e)
                self.lastCommit = nil
            },
            onClose: { [weak self] in self?.hidePanel() })
        showPanel(panel, hidesKeys: true)
    }

    private func showClipboard() {
        if hasFullAccess { clipboard.capture() }
        let notice = hasFullAccess ? nil :
            "履歴を残すには、設定アプリの「一般」→「キーボード」→「キーボード」→「DuoFlick」で「フルアクセスを許可」をオンにしてください。"
        let panel = TextListPanel(
            title: "クリップボード",
            store: clipboard,
            emptyMessage: "キーボードを開いている間にコピーした文字が、ここに残ります。",
            notice: notice,
            addTitle: nil,
            onAdd: nil,
            secondaryTitle: "定型文に",
            onSecondary: { [weak self] text in self?.phrases.add(text) },
            onSelect: { [weak self] text in self?.insertFromPanel(text) },
            onClose: { [weak self] in self?.hidePanel() })
        showPanel(panel, hidesKeys: true)
    }

    private func addPhraseFromSelection() {
        let selected = textDocumentProxy.selectedText ?? ""
        let text = selected.isEmpty ? (lastCommit?.text ?? "") : selected
        phrases.add(text)
    }

    private func insertFromPanel(_ text: String) {
        commitAll()
        composer.clearPredictions()
        textDocumentProxy.insertText(text)
        lastCommit = nil
        hidePanel()
        refreshBar()
    }

    private func showPanel<V: View>(_ panel: V, hidesKeys: Bool = false) {
        hidePanel()
        hideCandidateList()
        keyboardView.isHidden = hidesKeys
        middleHost?.view.isHidden = hidesKeys
        // 透けたパネルと候補の帯が重ならないよう、帯も隠す
        if hidesKeys { candidateBar.isHidden = true }
        let host = UIHostingController(rootView: panel)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: keyboardView.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        panelHost = host
    }

    private func hidePanel() {
        guard let host = panelHost else { return }
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        panelHost = nil
        keyboardView.isHidden = false
        middleHost?.view.isHidden = false
        candidateBar.isHidden = middleHost != nil
    }

    // MARK: - 単語登録

    private func startRegister() {
        commitAll()
        let selected = textDocumentProxy.selectedText ?? ""
        let word = selected.isEmpty ? (lastCommit?.text ?? "") : selected
        let reg = RegisterModel(word: word)
        register = reg
        setMode(.kana)
        let panel = RegisterPanel(
            model: reg,
            onSave: { [weak self] in self?.finishRegister(save: true) },
            onCancel: { [weak self] in self?.finishRegister(save: false) })
        showTop(UIHostingController(rootView: panel), height: registerHeight)
    }

    private func finishRegister(save: Bool) {
        if save, let reg = register {
            dictionary.add(word: reg.word, reading: reg.reading)
        }
        register = nil
        hideTop()
    }

    /// 単語登録中は、かなキーで読みを入力する（入力欄には入れない）
    private func handleRegisterKey(_ def: KeyDef, _ dir: FlickDirection, _ reg: RegisterModel) {
        switch def.action {
        case .kana(let chars), .direct(let chars):
            reg.reading += pick(chars, dir)
        case .modifier:
            if let last = reg.reading.last, let next = KeyCatalog.modified(String(last)) {
                reg.reading = String(reg.reading.dropLast()) + next
            }
        case .delete:
            if !reg.reading.isEmpty { reg.reading.removeLast() }
        case .newline:
            finishRegister(save: !reg.word.isEmpty && !reg.reading.isEmpty)
        case .settings, .nextKeyboard:
            finishRegister(save: false)
        default:
            break
        }
    }

    // MARK: - 重ねる画面

    /// バックアップをファイルにして共有画面を出す（「ファイルに保存」で残せる）。クリップボードにも入れる
    private func exportBackup() -> String {
        guard let json = Backup.makeJSON() else { return "バックアップを作れませんでした" }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DuoFlick-backup-\(f.string(from: Date())).json")
        do { try json.write(to: url, atomically: true, encoding: .utf8) } catch { return "ファイルを書き出せませんでした" }
        if hasFullAccess { UIPasteboard.general.string = json }
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = view
        share.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(share, animated: true)
        return hasFullAccess ? "共有画面を出しました。クリップボードにも入れました" : "共有画面を出しました"
    }

    /// クリップボードにあるバックアップを戻す
    private func restoreBackup() -> String {
        guard hasFullAccess else { return "フルアクセスが必要です" }
        guard let text = UIPasteboard.general.string, let n = Backup.restore(from: text) else {
            return "クリップボードにバックアップがありません"
        }
        return "\(n)項目を戻しました。キーボードを開き直すと反映されます"
    }

    private func showSettings() {
        hideTop()
        let actions = SettingsActions(
            onClose: { [weak self] in self?.hidePanel() },
            onAdjust: { [weak self] in self?.showAdjust() },
            onOptimize: { [weak self] in
                self?.hidePanel()
                self?.startOptimizing()
            },
            onRegister: { [weak self] in
                self?.hidePanel()
                self?.startRegister()
            },
            onPhrases: { [weak self] in self?.showPhrases() },
            onClipboard: { [weak self] in self?.showClipboard() },
            diagnose: { [weak self] in
                guard let self else { return "" }
                // 診断の前に、いまの設定と文脈を変換エンジン側へ反映する（変換のときまで反映されないため）
                self.composer.zenzai = self.model.settings.zenzai
                self.composer.zenzaiHigh = self.model.settings.zenzaiHigh
                self.updateLeftContext()
                var d = self.composer.diagnostics()
                let lines = self.savedRangeTrace
                d += "\n— 範囲選択の記録 —\n" + (lines.isEmpty ? "（まだ記録なし）" : lines.joined(separator: "\n"))
                return d
            },
            offsetText: { [weak self] in self?.keyboardView.offsetDescription ?? "" },
            onResetOffset: { [weak self] in self?.keyboardView.resetOffset() },
            onShowCorrection: { [weak self] in self?.showCorrection() },
            importSystemDictionary: { [weak self] done in
                self?.requestSupplementaryLexicon { lexicon in
                    DispatchQueue.main.async {
                        let items = lexicon.entries.map { (word: $0.documentText, reading: $0.userInput) }
                        let n = self?.dictionary.importSystem(items) ?? 0
                        done(n > 0 ? "\(n)語に入れ替えました" : "取り込める語がありませんでした")
                    }
                }
            },
            onBackup: { [weak self] in self?.exportBackup() ?? "" },
            onRestore: { [weak self] in self?.restoreBackup() ?? "" },
            onResetLearning: { [weak self] in self?.composer.resetLearning() })
        showPanel(SettingsScreen(model: model, dictionary: dictionary, actions: actions))
    }

    /// キーを見ながら大きさを変える帯を出す
    private func showAdjust() {
        hidePanel()
        let bar = AdjustBar(
            model: model,
            onBack: { [weak self] in self?.showSettings() },
            onClose: { [weak self] in self?.hideTop() })
        showTop(UIHostingController(rootView: bar), height: adjustHeight)
    }

    /// 補正を見る：キーの上に、ずれと方向の境目を重ねて出す
    private func showCorrection() {
        hidePanel()
        let bar = CorrectionBar(
            onBack: { [weak self] in
                self?.keyboardView.showCorrection = false
                self?.showSettings()
            },
            onClose: { [weak self] in self?.hideTop() })
        showTop(UIHostingController(rootView: bar), height: adjustHeight)
        keyboardView.showCorrection = true   // showTop が一度 hideTop を通るので、そのあとで立てる
    }

    private func showTop(_ host: UIViewController, height: CGFloat) {
        hideTop()
        keyboardTop?.isActive = false
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.heightAnchor.constraint(equalToConstant: height),
        ])
        let top = keyboardView.topAnchor.constraint(equalTo: host.view.bottomAnchor)
        top.isActive = true
        keyboardTop = top
        topHost = host
        topHeight = height
        updateHeight(force: true)
    }

    private func hideTop() {
        keyboardView.showCorrection = false
        guard let host = topHost else { return }
        keyboardTop?.isActive = false
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        topHost = nil
        topHeight = 0
        let top = keyboardView.topAnchor.constraint(equalTo: view.topAnchor)
        top.isActive = true
        keyboardTop = top
        updateHeight(force: true)
    }

}
