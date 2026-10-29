import UIKit

/// キーボード上部の変換候補の帯。横にスクロールできる。
final class CandidateBar: UIView, UIGestureRecognizerDelegate {
    static let height: CGFloat = 44

    var onSelect: ((Int) -> Void)?
    /// 右端の∨／∧ボタン（候補の一覧を開く・閉じる）
    var onExpand: (() -> Void)?
    /// 帯を下にフリックしたとき（キーボードを閉じる）
    var onSwipeDown: (() -> Void)?

    private let scroll = UIScrollView()
    private let expandButton = UIButton(type: .system)
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swipedDown))
        swipe.direction = .down
        swipe.cancelsTouchesInView = true
        swipe.delegate = self
        addGestureRecognizer(swipe)
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        stack.axis = .horizontal
        stack.spacing = 4
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        expandButton.translatesAutoresizingMaskIntoConstraints = false
        expandButton.tintColor = Palette.text
        expandButton.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        expandButton.addTarget(self, action: #selector(expandTapped), for: .touchUpInside)
        expandButton.isHidden = true
        addSubview(expandButton)
        // 下にフリックすると閉じられることを示す、つまみの形のバー
        let grabber = UIView()
        grabber.translatesAutoresizingMaskIntoConstraints = false
        grabber.backgroundColor = Palette.text.withAlphaComponent(0.3)
        grabber.layer.cornerRadius = 2
        grabber.isUserInteractionEnabled = false
        addSubview(grabber)
        NSLayoutConstraint.activate([
            grabber.centerXAnchor.constraint(equalTo: centerXAnchor),
            grabber.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            grabber.widthAnchor.constraint(equalToConstant: 36),
            grabber.heightAnchor.constraint(equalToConstant: 4),
        ])
        NSLayoutConstraint.activate([
            expandButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            expandButton.topAnchor.constraint(equalTo: topAnchor),
            expandButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            expandButton.widthAnchor.constraint(equalToConstant: 48),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: expandButton.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func swipedDown() { onSwipeDown?() }

    // 横スクロールや候補のタップと一緒に判定する
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    /// 帯に並べる候補の上限（多すぎると重くなるため）
    static let maxItems = 30

    private var shownItems: [String] = []
    private var shownSelected: Int?

    func show(_ items: [String], selected: Int?) {
        let list = Array(items.prefix(Self.maxItems))
        // 同じ内容なら作り直さない（ちらつきと無駄な処理を防ぐ）
        if list == shownItems && selected == shownSelected { return }
        let wasEmpty = shownItems.isEmpty
        shownItems = list
        shownSelected = selected
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        for (i, text) in items.prefix(Self.maxItems).enumerated() {
            var config = UIButton.Configuration.plain()
            var title = AttributedString(text)
            title.font = UIFont.systemFont(ofSize: 19)
            config.attributedTitle = title
            config.titleLineBreakMode = .byClipping
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
            config.baseForegroundColor = i == selected ? Palette.pressedText : Palette.text
            config.background.backgroundColor = i == selected ? Palette.pressed : .clear
            config.background.cornerRadius = 8
            let b = UIButton(configuration: config)
            b.tag = i
            // 文字の幅のぶんだけ場所を取り、隣の候補と重ならないようにする
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
            b.setContentHuggingPriority(.required, for: .horizontal)
            b.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
            stack.addArrangedSubview(b)
        }
        // 候補が出始めるときは、上から下へスライドして出す
        if wasEmpty, !list.isEmpty {
            stack.alpha = 0
            stack.transform = CGAffineTransform(translationX: 0, y: -14)
            UIView.animate(withDuration: 0.18, delay: 0, options: .curveEaseOut) {
                self.stack.alpha = 1
                self.stack.transform = .identity
            }
        }
        if let s = selected, s < stack.arrangedSubviews.count {
            layoutIfNeeded()
            scroll.scrollRectToVisible(stack.arrangedSubviews[s].frame.insetBy(dx: -40, dy: 0), animated: true)
        } else {
            scroll.setContentOffset(.zero, animated: false)
        }
    }

    /// ∨ボタンを出すか、一覧を開いているか（開いているときは∧）
    func setExpand(visible: Bool, expanded: Bool) {
        expandButton.isHidden = !visible
        expandButton.setImage(UIImage(systemName: expanded ? "chevron.up" : "chevron.down"), for: .normal)
    }

    @objc private func expandTapped() {
        onExpand?()
    }

    @objc private func tapped(_ b: UIButton) {
        onSelect?(b.tag)
    }
}
