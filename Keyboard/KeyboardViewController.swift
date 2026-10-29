import UIKit
import SwiftUI

/// キー音（iOSのキーボードのクリック音）を鳴らすための入力ビュー
final class ClickInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

final class KeyboardViewController: UIInputViewController {
    private let model = SettingsModel()
    private let keyboardView = KeyboardView()
    private let candidateBar = CandidateBar()
    private let guideView = GuideOverlayView()
    private let composer = Composer()
    private var tuningHost: UIHostingController<TuningBar>?
    private var heightConstraint: NSLayoutConstraint?
    private var keyboardTop: NSLayoutConstraint?
    private let tuningHeight: CGFloat = 160
    private var lastWidth: CGFloat = 0
    private var mode: InputMode = .kana

    /// 直前に確定した文字と読み（↺で取り消すため）
    private var lastCommit: (text: String, reading: String)?

    override func loadView() {
        inputView = ClickInputView(frame: .zero, inputViewStyle: .keyboard)
    }

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
        keyboardView.settings = model.settings
        keyboardView.onKey = { [weak self] def, dir in self?.handle(def, dir) }
        keyboardView.onPress = { [weak self] in
            if self?.model.settings.keySound == true { UIDevice.current.playInputClick() }
        }
        keyboardView.onCursor = { [weak self] steps in self?.moveCursor(steps) }
        keyboardView.onCursorVertical = { [weak self] lines in self?.moveCursorVertically(lines) }
        candidateBar.onSelect = { [weak self] i in self?.commitCandidate(i) }
        candidateBar.onTool = { [weak self] id in self?.handleTool(id) }
        model.onChange = { [weak self] s in
            guard let self else { return }
            s.save()
            self.keyboardView.settings = s
            self.updateHeight(force: true)
            self.refreshBar()
        }
        refreshBar()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyKeyboardType()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateHeight(force: false)
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        applyKeyboardType()
    }

    /// 入力欄の種類に合わせて、最初の文字種を選ぶ
    private var lastKeyboardType: UIKeyboardType?
    private func applyKeyboardType() {
        let type = textDocumentProxy.keyboardType ?? .default
        guard type != lastKeyboardType else { return }
        lastKeyboardType = type
        switch type {
        case .emailAddress, .URL, .asciiCapable, .twitter, .webSearch, .asciiCapableNumberPad:
            setMode(type == .asciiCapableNumberPad ? .number : .alpha)
        case .numberPad, .phonePad, .decimalPad, .numbersAndPunctuation, .namePhonePad:
            setMode(.number)
        default:
            setMode(.kana)
        }
    }

    private func setMode(_ m: InputMode) {
        if m != .kana { commitAll() }
        mode = m
        keyboardView.mode = m
        updateHeight(force: true)
    }

    private func updateHeight(force: Bool) {
        let w = view.bounds.width
        guard w > 0 else { return }
        if !force && w == lastWidth { return }
        lastWidth = w
        let h = keyboardView.requiredHeight(for: w) + (tuningHost == nil ? 0 : tuningHeight)
        if heightConstraint?.constant != h { heightConstraint?.constant = h }
    }

    // MARK: - 入力

    private func handle(_ def: KeyDef, _ dir: FlickDirection) {
        let proxy = textDocumentProxy
        if case .undo = def.action {
            undoCommit()
            return
        }
        lastCommit = nil

        switch def.action {
        case .kana(let chars):
            let c = chars[dir.rawValue]
            let s = c.isEmpty ? chars[0] : c
            if isPunctuation(s) {
                // 句読点は、入力中の文字を確定してからそのまま入れる
                commitAll()
                proxy.insertText(s)
            } else {
                if composer.selectedIndex != nil { commitAll() }
                composer.insert(s)
                updateComposition()
            }
        case .direct(let chars):
            commitAll()
            let c = chars[dir.rawValue]
            proxy.insertText(c.isEmpty ? chars[0] : c)
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
        case .caseToggle:
            if let last = proxy.documentContextBeforeInput?.last, last.isLetter, last.isASCII {
                let s = String(last)
                let swapped = s == s.lowercased() ? s.uppercased() : s.lowercased()
                proxy.deleteBackward()
                proxy.insertText(swapped)
            }
        case .delete:
            if dir == .left {
                deleteWord()
            } else if composer.isEmpty {
                proxy.deleteBackward()
            } else {
                composer.deleteBackward()
                updateComposition()
            }
        case .space:
            if composer.isEmpty {
                proxy.insertText(mode == .kana ? "　" : " ")
            } else {
                composer.selectNext()
                updateComposition()
            }
        case .newline:
            if composer.isEmpty {
                proxy.insertText("\n")
            } else {
                commitAll()
            }
        case .modeSwitch:
            setMode(mode.next)
        case .settings:
            toggleTuning()
        case .nextKeyboard:
            commitAll()
            advanceToNextInputMode()
        case .undo:
            break
        }
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
        let proxy = textDocumentProxy
        guard let before = proxy.documentContextBeforeInput, let last = before.last else { return }
        var count = 0
        if last.isWhitespace || last.isNewline {
            count = before.reversed().prefix { $0.isWhitespace || $0.isNewline }.count
        } else {
            let kind = charKind(last)
            count = before.reversed().prefix { charKind($0) == kind }.count
        }
        for _ in 0..<max(1, count) { proxy.deleteBackward() }
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

    private func moveCursor(_ steps: Int) {
        commitAll()
        textDocumentProxy.adjustTextPosition(byCharacterOffset: steps)
    }

    /// 上下の行へ移動する。改行で区切られた行が対象（折り返しは iOS から位置が分からないため対象外）
    private func moveCursorVertically(_ lines: Int) {
        commitAll()
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

    /// 入力欄の下線付きの文字と、変換候補の帯を更新する
    private func updateComposition() {
        let proxy = textDocumentProxy
        if composer.isEmpty {
            proxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
            proxy.unmarkText()
        } else {
            let text = composer.markedText
            proxy.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
        }
        refreshBar()
    }

    private func refreshBar() {
        if composer.isEmpty {
            let s = model.settings
            let oneHand = s.shape != .standard
            candidateBar.showTools([
                .init(id: "left", title: "左手", on: oneHand && s.hand == .left),
                .init(id: "both", title: "両手", on: !oneHand),
                .init(id: "right", title: "右手", on: oneHand && s.hand == .right),
            ])
        } else {
            candidateBar.show(composer.candidateTexts, selected: composer.selectedIndex)
        }
    }

    private func handleTool(_ id: String) {
        var s = model.settings
        switch id {
        case "left", "right":
            s.hand = id == "left" ? .left : .right
            if s.shape == .standard { s.shape = s.oneHandShape }
        case "both":
            if s.shape != .standard { s.oneHandShape = s.shape }
            s.shape = .standard
        default:
            return
        }
        model.settings = s
    }

    private func commitCandidate(_ index: Int) {
        let reading = composer.reading
        guard let text = composer.commit(candidateAt: index) else { return }
        let proxy = textDocumentProxy
        proxy.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
        proxy.unmarkText()
        if composer.isEmpty { lastCommit = (text, reading) }
        updateComposition()
    }

    private func commitAll() {
        guard !composer.isEmpty else { return }
        let reading = composer.reading
        let text = composer.commitAll()
        let proxy = textDocumentProxy
        proxy.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
        proxy.unmarkText()
        lastCommit = (text, reading)
        refreshBar()
    }

    // MARK: - 調整バー

    private func toggleTuning() {
        keyboardTop?.isActive = false
        if let host = tuningHost {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
            tuningHost = nil
            let top = keyboardView.topAnchor.constraint(equalTo: view.topAnchor)
            top.isActive = true
            keyboardTop = top
        } else {
            let host = UIHostingController(rootView: TuningBar(model: model, onClose: { [weak self] in
                self?.toggleTuning()
            }))
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            addChild(host)
            view.addSubview(host.view)
            host.didMove(toParent: self)
            NSLayoutConstraint.activate([
                host.view.topAnchor.constraint(equalTo: view.topAnchor),
                host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                host.view.heightAnchor.constraint(equalToConstant: tuningHeight),
            ])
            let top = keyboardView.topAnchor.constraint(equalTo: host.view.bottomAnchor)
            top.isActive = true
            keyboardTop = top
            tuningHost = host
        }
        updateHeight(force: true)
    }
}
