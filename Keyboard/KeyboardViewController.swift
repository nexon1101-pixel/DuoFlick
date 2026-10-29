import UIKit
import SwiftUI

final class KeyboardViewController: UIInputViewController {
    private let model = SettingsModel()
    private let keyboardView = KeyboardView()
    private var tuningHost: UIHostingController<TuningBar>?
    private var heightConstraint: NSLayoutConstraint?
    private var keyboardTop: NSLayoutConstraint?
    private let tuningHeight: CGFloat = 132
    private var lastWidth: CGFloat = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.background

        keyboardView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyboardView)
        NSLayoutConstraint.activate([
            keyboardView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboardView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let top = keyboardView.topAnchor.constraint(equalTo: view.topAnchor)
        top.isActive = true
        keyboardTop = top

        let height = view.heightAnchor.constraint(equalToConstant: 260)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        heightConstraint = height

        keyboardView.settings = model.settings
        keyboardView.onKey = { [weak self] def, dir in self?.handle(def, dir) }
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
            proxy.insertText(c.isEmpty ? chars[0] : c)
        case .modifier:
            if let last = proxy.documentContextBeforeInput?.last,
               let next = KeyCatalog.modified(String(last)) {
                proxy.deleteBackward()
                proxy.insertText(next)
            }
        case .delete:
            proxy.deleteBackward()
        case .space:
            proxy.insertText("　")
        case .newline:
            proxy.insertText("\n")
        case .cursorLeft:
            proxy.adjustTextPosition(byCharacterOffset: -1)
        case .cursorRight:
            proxy.adjustTextPosition(byCharacterOffset: 1)
        case .settings:
            toggleTuning()
        case .nextKeyboard:
            advanceToNextInputMode()
        }
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
