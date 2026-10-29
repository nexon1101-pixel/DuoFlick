import UIKit
import SwiftUI

final class KeyboardViewController: UIInputViewController {
    private let model = SettingsModel()
    private let dictionary = UserDictionaryStore()
    private let keyboardView = KeyboardView()
    private let candidateBar = CandidateBar()
    private let guideView = GuideOverlayView()
    private let composer = Composer()
    private let optimizer = OptimizerModel()
    /// 打ち比べの最中（キー入力はお題の採点に使い、入力欄には入れない）
    private var optimizing = false
    private let phrases = PhraseStore()
    private let clipboard = ClipboardStore()
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private var clipboardTimer: Timer?
    private var heightConstraint: NSLayoutConstraint?
    private var keyboardTop: NSLayoutConstraint?
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

        for v in [keyboardView, candidateBar, guideView] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        NSLayoutConstraint.activate([
            keyboardView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboardView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            // 変換候補の帯はキーボードの上部に重ねる（キーはその下から並ぶ）
            candidateBar.topAnchor.constraint(equalTo: keyboardView.topAnchor),
            candidateBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            candidateBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            candidateBar.heightAnchor.constraint(equalToConstant: CandidateBar.height),
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
        keyboardView.onPinch = { [weak self] split in
            guard let self else { return }
            // 片手持ちでピンチアウトしたら、両手持ちにして分割する
            if split, self.model.grip == .one {
                self.commitAll()
                self.model.toggleGrip()
                self.splitFromOne = true
            }
            guard self.model.grip == .two, self.model.settings.splitKana != split else { return }
            self.model.settings.splitKana = split
            // 片手持ちから分割したときは、ピンチインで片手持ちに戻す
            if !split, self.splitFromOne {
                self.splitFromOne = false
                self.commitAll()
                self.model.toggleGrip()
            }
        }
        keyboardView.onKey = { [weak self] def, dir in self?.handle(def, dir) }
        keyboardView.onPress = { [weak self] in
            guard let self, self.model.settings.haptics, self.hasFullAccess else { return }
            self.haptic.impactOccurred()
        }
        keyboardView.onCursor = { [weak self] steps in self?.cursorDrag(steps) }
        keyboardView.onCursorVertical = { [weak self] lines in self?.moveCursorVertically(lines) }
        candidateBar.onSelect = { [weak self] i in self?.selectFromBar(i) }
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
        }
        refreshBar()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyKeyboardType()
        haptic.prepare()
        // キーボードを開いている間にコピーされたものを、クリップボードの履歴に残す
        if hasFullAccess {
            clipboard.capture()
            clipboardTimer?.invalidate()
            clipboardTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.clipboard.capture()
            }
        }
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
    }

    /// 入力欄の種類に合わせて、最初の文字種を選ぶ
    private var lastKeyboardType: UIKeyboardType?
    private func applyKeyboardType() {
        let type = textDocumentProxy.keyboardType ?? .default
        guard type != lastKeyboardType else { return }
        lastKeyboardType = type
        switch type {
        case .emailAddress, .URL, .asciiCapable, .twitter, .webSearch:
            japanese = false
            setMode(.qwerty)
        case .numberPad, .phonePad, .decimalPad, .numbersAndPunctuation, .namePhonePad, .asciiCapableNumberPad:
            japanese = false
            setMode(.symbol)
        default:
            setMode(.kana)
        }
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
        domainCandidates = []
        let expectedClose = pairClose
        pairClose = nil
        // 変換待ち（読みに下線が出ている間）は、ABC・地球儀・片手／両手などの、入力を中断するキーが押せない（設定でオフにできる）
        if composingLocked, !isAllowedWhileComposing(def) { return }
        let proxy = textDocumentProxy
        // ⌫の右フリック：確定の取り消し（↺）
        if case .delete = def.action, dir == .right {
            // 続けてタップの途中なら、ひとつ前の文字に戻す（iOS標準の↺と同じ）
            if let t = toggle, let chars = t.def.flickChars, applyToggle(t.def, chars, step: -1) {
                return
            }
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
            // 句読点も読みに足す（単独でも変換の候補が出る）。候補を選んでいたら先に確定する
            if composer.selectedIndex != nil { commitAll() }
            composer.insert(s)
            updateComposition()
        case .direct(let chars) where def.id.hasPrefix("digit") && !isNumericField:
            // 数字も読みに足して変換する（全角・漢数字の候補が出る。候補を選んでいたら先に確定する）
            if composer.selectedIndex != nil { commitAll() }
            composer.insert(pick(chars, dir))
            updateComposition()
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
        case .widthToggle:
            // パソコンの全角／半角キーと同じ：日本語（ローマ字かな）⇄英字
            commitAll()
            japanese.toggle()
            shiftState = .off
            updateKeyLabels()
        case .cursorRight:
            cursorDrag(1)
        case .undoCommit:
            undoCommit()
        case .paste:
            if let text = UIPasteboard.general.string, !text.isEmpty {
                commitAll()
                composer.clearPredictions()
                proxy.insertText(text)
                refreshBar()
            }
        case .numberPad:
            break
        case .gripSwitch:
            commitAll()
            hideTop()
            hidePanel()
            model.toggleGrip()
        case .delete:
            if dir == .left {
                deleteWord()
            } else if composer.isEmpty {
                composer.clearPredictions()
                proxy.deleteBackward()
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
        case .settings:
            toggleSettings()
        case .nextKeyboard:
            // 地球儀：タップでキーボードを切り替え、上で設定、左で定型文、右でクリップボード
            switch dir {
            case .up: toggleSettings()
            case .left: showPhrases()
            case .right: showClipboard()
            default:
                commitAll()
                advanceToNextInputMode()
            }
        }
    }

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

    /// 変換待ちの間に止めるキー：入力を中断してしまう、ABC・地球儀・片手／両手・設定・記号面・貼り付けなどのキー。
    /// かな・数字・⌫・空白（次候補）・改行（確定）・小゛゜など、読みを打ち続けるキーは止めない
    private func isAllowedWhileComposing(_ def: KeyDef) -> Bool {
        switch def.action {
        case .modeSwitch, .nextKeyboard, .gripSwitch, .settings, .layer, .paste, .widthToggle: return false
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
        guard let last = lastCommit, let before = proxy.documentContextBeforeInput,
              before.hasSuffix(last.text) else { return }
        for _ in 0..<last.text.count { proxy.deleteBackward() }
        lastCommit = nil
        composer.restore(reading: last.reading)
        updateComposition()
    }

    /// 空白キー長押しの左右：入力中なら文節の区切りを動かし、そうでなければカーソルを動かす
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

    /// 上下の行へ移動する。改行で区切られた行が対象（折り返しは iOS から位置が分からないため対象外）
    private func moveCursorVertically(_ lines: Int) {
        guard composer.isEmpty, register == nil else { return }
        composer.clearPredictions()
        refreshBar()
        let proxy = textDocumentProxy
        for _ in 0..<abs(lines) {
            let before = proxy.documentContextBeforeInput ?? ""
            let after = proxy.documentContextAfterInput ?? ""
            let beforeChars = Array(before)
            let col = beforeChars.reversed().prefix { $0 != "\n" }.count
            if lines < 0 {
                // 前の行の同じ位置へ
                let lineStart = beforeChars.count - col
                guard lineStart > 0 else { proxy.adjustTextPosition(byCharacterOffset: -col); return }
                let prevPart = Array(beforeChars[0..<(lineStart - 1)])
                let prevLen = prevPart.reversed().prefix { $0 != "\n" }.count
                let target = (lineStart - 1 - prevLen) + min(col, prevLen)
                proxy.adjustTextPosition(byCharacterOffset: target - beforeChars.count)
            } else {
                // 次の行の同じ位置へ
                let afterChars = Array(after)
                guard let nl = afterChars.firstIndex(of: "\n") else {
                    proxy.adjustTextPosition(byCharacterOffset: afterChars.count); return
                }
                let rest = afterChars[(nl + 1)...]
                let nextLen = rest.prefix { $0 != "\n" }.count
                proxy.adjustTextPosition(byCharacterOffset: nl + 1 + min(col, nextLen))
            }
        }
    }

    // MARK: - 入力欄への反映（本家 azooKey と同じく、確定は insertText で下線付きの文字を置き換える）

    /// 入力欄に下線付きの文字があるか
    private var markedActive = false

    private func showMarked(_ text: String) {
        textDocumentProxy.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
        markedActive = true
    }

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
    }

    /// 入力欄の下線付きの文字と、変換候補の帯を更新する
    private func updateComposition() {
        composer.typoCorrection = model.settings.typoCorrection
        hideCandidateList()
        if composer.isEmpty {
            clearMarked()
        } else {
            showMarked(composer.markedText)
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
    private func scheduleCandidates() {
        candidateWork?.cancel()
        guard composer.needsRefresh else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.composer.refreshIfNeeded()
            self.refreshBar()
        }
        candidateWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// 入力中は変換候補、確定直後は予測、それ以外は何も出さない
    private func refreshBar() {
        updateKeyLabels()
        if !composer.isEmpty {
            pasteChip = false
            showBar(composer.candidateTexts, selected: composer.selectedIndex)
        } else {
            pasteChip = false
            englishWords = domainCandidates.isEmpty ? currentEnglishCompletions() : []
            if !englishWords.isEmpty {
                showBar(englishWords, selected: nil)
            } else {
                let items = domainCandidates.isEmpty ? composer.predictionTexts : domainCandidates
                // 出す候補がなく、クリップボードに文字があるときは、貼り付けを出す
                pasteChip = items.isEmpty && hasFullAccess && UIPasteboard.general.hasStrings
                showBar(pasteChip ? ["貼り付け"] : items, selected: nil)
            }
            hideCandidateList()
        }
        let canExpand = !composer.isEmpty && !composer.candidateTexts.isEmpty
        if !canExpand { hideCandidateList() }
        candidateBar.setExpand(visible: canExpand, expanded: listHost != nil)
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
        if mode != .kana { labels["space"] = composer.isEmpty ? (japanese ? "空白" : "space") : "次候補" }
        keyboardView.labelOverrides = labels
        keyboardView.accentIDs = accent
        keyboardView.disabledIDs = disabled
        updateShiftDisplay()
    }

    // MARK: - 候補の一覧

    private var listHost: UIHostingController<CandidateList>?

    private func toggleCandidateList() {
        if listHost != nil { hideCandidateList(); refreshBar(); return }
        composer.refreshIfNeeded()
        let list = CandidateList(items: composer.listTexts) { [weak self] i in
            guard let self else { return }
            self.hideCandidateList()
            self.commitCandidate(i)
        }
        let host = UIHostingController(rootView: list)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: candidateBar.bottomAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        listHost = host
        // 一覧を開いている間は、キーが透けて文字と重ならないよう、キーを隠す
        keyboardView.isHidden = true
        middleHost?.view.isHidden = true
        candidateBar.setExpand(visible: true, expanded: true)
    }

    private func hideCandidateList() {
        guard let host = listHost else { return }
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        listHost = nil
        keyboardView.isHidden = false
        middleHost?.view.isHidden = false
    }

    /// 「@」のあとに出す、よく使うメールのドメイン
    private var domainCandidates: [String] = []
    /// 括弧を対で入れた直後の、閉じ括弧
    private var pairClose: String?
    private static let bracketPairs = ["(": ")", "[": "]", "{": "}"]
    private static let mailDomains = [
        "gmail.com", "icloud.com", "yahoo.co.jp", "outlook.jp", "outlook.com", "docomo.ne.jp",
        "ezweb.ne.jp", "au.com", "softbank.ne.jp", "i.softbank.jp", "hotmail.co.jp", "hotmail.com",
        "yahoo.com", "live.jp", "nifty.com", "ybb.ne.jp"
    ]

    // MARK: - 真ん中の候補の一覧（iOS標準の配置）

    private var splitFromOne = false
    private let panelModel = PanelModel()
    private var middleHost: UIHostingController<MiddlePanel>?

    private func showBar(_ items: [String], selected: Int?) {
        candidateBar.show(items, selected: selected)
        panelModel.items = composer.isEmpty ? items : composer.listTexts
        panelModel.selected = selected
    }

    private func updateMiddlePanel(_ rect: CGRect?) {
        // 真ん中に候補を出すときは、上の候補の帯は要らない
        candidateBar.isHidden = rect != nil
        guard let rect else {
            if let h = middleHost {
                h.willMove(toParent: nil); h.view.removeFromSuperview(); h.removeFromParent()
                middleHost = nil
            }
            return
        }
        if middleHost == nil {
            let host = UIHostingController(rootView: MiddlePanel(model: panelModel) { [weak self] i in
                self?.selectFromBar(i)
            })
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

    private func selectFromBar(_ index: Int) {
        if pasteChip, composer.isEmpty {
            if let text = UIPasteboard.general.string, !text.isEmpty {
                composer.clearPredictions()
                textDocumentProxy.insertText(text)
                lastCommit = nil
            }
            refreshBar()
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
            if composer.needsRefresh {
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

    private func commitCandidate(_ index: Int) {
        let reading = composer.reading
        guard let text = composer.commit(candidateAt: index) else { return }
        insertCommitted(text)
        if composer.isEmpty {
            lastCommit = (text, reading)
            refreshBar()
            schedulePredictions()
        } else {
            updateComposition()
        }
    }

    private func commitAll() {
        guard !composer.isEmpty else { return }
        let reading = composer.reading
        let text = composer.commitAll()
        insertCommitted(text)
        lastCommit = (text, reading)
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
        showPanel(panel)
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
        showPanel(panel)
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

    private func showPanel<V: View>(_ panel: V) {
        hidePanel()
        hideCandidateList()
        let host = UIHostingController(rootView: panel)
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
            diagnose: { [weak self] in self?.composer.diagnostics() ?? "" },
            offsetText: { [weak self] in self?.keyboardView.offsetDescription ?? "" },
            onResetOffset: { [weak self] in self?.keyboardView.resetOffset() },
            importSystemDictionary: { [weak self] done in
                self?.requestSupplementaryLexicon { lexicon in
                    DispatchQueue.main.async {
                        let items = lexicon.entries.map { (word: $0.documentText, reading: $0.userInput) }
                        let n = self?.dictionary.importSystem(items) ?? 0
                        done(n > 0 ? "\(n)語を取り込みました" : "取り込める語がありませんでした")
                    }
                }
            })
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
