import UIKit
import SwiftUI

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
        keyboardView.onCursor = { [weak self] steps in self?.moveCursor(steps) }
        candidateBar.onSelect = { [weak self] i in self?.commitCandidate(i) }
        model.onChange = { [weak self] s in
            guard let self else { return }
            s.save()
            self.keyboardView.settings = s
            self.updateHeight(force: true)
        }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateHeight(force: false)
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
        case .delete:
            if composer.isEmpty {
                proxy.deleteBackward()
            } else {
                composer.deleteBackward()
                updateComposition()
            }
        case .space:
            if composer.isEmpty {
                proxy.insertText("　")
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
        case .cursorLeft:
            moveCursor(-1)
        case .cursorRight:
            moveCursor(1)
        case .settings:
            toggleTuning()
        case .nextKeyboard:
            commitAll()
            advanceToNextInputMode()
        }
    }

    private func isPunctuation(_ s: String) -> Bool {
        ["、", "。", "？", "！", "「", "」"].contains(s)
    }

    private func moveCursor(_ steps: Int) {
        commitAll()
        textDocumentProxy.adjustTextPosition(byCharacterOffset: steps)
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
        candidateBar.show(composer.candidateTexts, selected: composer.selectedIndex)
    }

    private func commitCandidate(_ index: Int) {
        guard let text = composer.commit(candidateAt: index) else { return }
        let proxy = textDocumentProxy
        proxy.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
        proxy.unmarkText()
        updateComposition()
    }

    private func commitAll() {
        guard !composer.isEmpty else { return }
        let text = composer.commitAll()
        let proxy = textDocumentProxy
        proxy.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
        proxy.unmarkText()
        candidateBar.show([], selected: nil)
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
