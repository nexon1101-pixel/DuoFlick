import UIKit

/// キーボード上部の変換候補の帯。横にスクロールできる。
final class CandidateBar: UIView, UIGestureRecognizerDelegate {
    static let height: CGFloat = 44
    /// ライブ変換のとき、読みを出すために帯の上に足す余白
    static let readingMargin: CGFloat = 8
    /// 候補の上に空ける余白（読みを出すとき）
    var topMargin: CGFloat = 0 {
        didSet {
            scrollTop.constant = topMargin
            expandTop.constant = topMargin
        }
    }

    var onSelect: ((Int) -> Void)?
    /// 候補を長押ししたとき（先頭の文節だけ確定する）
    var onLongPress: ((Int) -> Void)?
    /// 長押しが成立したボタン。その直後のタップ（指を離したときの通常選択）は飲み込む
    private var longPressedTag: Int?
    /// 左上の読み（ひらがな）を押したとき
    var onReading: (() -> Void)?
    /// 右端の∨／∧ボタン（候補の一覧を開く・閉じる）
    var onExpand: (() -> Void)?
    /// 帯を下にフリックしたとき（キーボードを閉じる）
    var onSwipeDown: (() -> Void)?

    private let scroll = UIScrollView()
    private let expandButton = UIButton(type: .system)
    private let stack = UIStackView()
    private lazy var scrollTop = scroll.topAnchor.constraint(equalTo: topAnchor)
    private lazy var expandTop = expandButton.topAnchor.constraint(equalTo: topAnchor)
    /// ライブ変換で、打った読みを帯の左上に小さく出す（高さは増やさない。押すとひらがなで確定）
    private let readingButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        // 下へのフリック：短い動きでも拾えるよう、スワイプではなくパンで見る（候補がないときも働く）
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
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
            expandTop,
            expandButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            expandButton.widthAnchor.constraint(equalToConstant: 48),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: expandButton.leadingAnchor),
            scrollTop,
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        setupReadingButton()
    }

    private func setupReadingButton() {
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 8)
        readingButton.configuration = config
        readingButton.translatesAutoresizingMaskIntoConstraints = false
        readingButton.isHidden = true
        readingButton.addAction(UIAction { [weak self] _ in self?.onReading?() }, for: .touchUpInside)
        addSubview(readingButton)
        NSLayoutConstraint.activate([
            readingButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            readingButton.topAnchor.constraint(equalTo: topAnchor, constant: 0),
            readingButton.heightAnchor.constraint(equalToConstant: 14)   // 余白より少し高く、候補の上の空きに重ねる,
        ])
    }

    private func updateReadingButton(_ reading: String?, hasItems: Bool) {
        guard let reading, !reading.isEmpty, hasItems else { readingButton.isHidden = true; return }
        var title = AttributedString(reading)
        title.font = UIFont.systemFont(ofSize: 11)
        readingButton.configuration?.attributedTitle = title
        readingButton.configuration?.baseForegroundColor = Palette.text.withAlphaComponent(0.6)
        readingButton.isHidden = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var panFired = false

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began: panFired = false
        case .changed:
            let t = g.translation(in: self)
            if !panFired, t.y > 22, abs(t.x) < t.y {
                panFired = true
                onSwipeDown?()
            }
        default: break
        }
    }

    /// 下向きで、縦の動きが大きいときだけ始める（横スクロールや候補のタップの邪魔をしない）
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let v = pan.velocity(in: self)
        return v.y > 0 && abs(v.y) > abs(v.x) * 1.2
    }

    // 横スクロールや候補のタップと一緒に判定する
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    /// 帯に並べる候補の上限（多すぎると重くなるため）
    static let maxItems = 30

    private var shownItems: [String] = []
    private var shownSelected: Int?

    private var shownDimmed = false
    private var shownReading: String?
    private lazy var centerWidth = stack.widthAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor, constant: -16)

    /// dimmed が true のときは、文字を薄いグレーにする（「コピー内容の貼り付け」など、候補ではない案内用）
    func show(_ items: [String], selected: Int?, dimmed: Bool = false, reading: String? = nil) {
        // フリック中に帯が作り直されると、スクロール位置が0に戻って
        // フリックが途切れる。ドラッグ中・減速中は位置を保つ。
        let wasInteracting = scroll.isDragging || scroll.isDecelerating
        let previousOffset = scroll.contentOffset
        let list = Array(items.prefix(Self.maxItems))
        // 同じ内容なら作り直さない（ちらつきと無駄な処理を防ぐ）
        if list == shownItems && selected == shownSelected && dimmed == shownDimmed && reading == shownReading { return }
        shownReading = reading
        updateReadingButton(reading, hasItems: !list.isEmpty)
        shownDimmed = dimmed
        // 案内（コピー内容の貼り付けなど）は、帯の真ん中に出す
        centerWidth.isActive = dimmed
        stack.distribution = dimmed ? .equalCentering : .fill
        let wasEmpty = shownItems.isEmpty
        // 候補がなくなるときは、上へスライドしながら消す
        if list.isEmpty, !wasEmpty, let snap = stack.snapshotView(afterScreenUpdates: false) {
            snap.frame = scroll.convert(stack.frame, to: self)
            addSubview(snap)
            UIView.animate(withDuration: 0.16, delay: 0, options: .curveEaseIn, animations: {
                snap.alpha = 0
                snap.transform = CGAffineTransform(translationX: 0, y: -14)
            }, completion: { _ in snap.removeFromSuperview() })
        }
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
            config.baseForegroundColor = i == selected ? Palette.pressedText : (dimmed ? Palette.text.withAlphaComponent(0.45) : Palette.text)
            config.background.backgroundColor = i == selected ? Palette.pressed : .clear
            config.background.cornerRadius = 8
            let b = UIButton(configuration: config)
            b.tag = i
            // 文字の幅のぶんだけ場所を取り、隣の候補と重ならないようにする
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
            b.setContentHuggingPriority(.required, for: .horizontal)
            b.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
            let lp = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
            lp.minimumPressDuration = 0.4
            b.addGestureRecognizer(lp)
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
        if let s = selected, let target = stack.arrangedSubviews.first(where: { ($0 as? UIButton)?.tag == s }) {
            layoutIfNeeded()
            scroll.scrollRectToVisible(target.frame.insetBy(dx: -40, dy: 0), animated: true)
        } else if wasInteracting {
            // フリック中は位置を保つ。内容の幅が変わったら、はみ出さない範囲に収める。
            layoutIfNeeded()
            let maxX = max(0, scroll.contentSize.width - scroll.bounds.width)
            scroll.setContentOffset(CGPoint(x: min(max(previousOffset.x, 0), maxX), y: 0), animated: false)
        } else {
            scroll.setContentOffset(.zero, animated: false)
        }
    }

    /// 帯の横スクロール（減速中も含む）をその場で止める。
    func stopScrolling() {
        scroll.setContentOffset(scroll.contentOffset, animated: false)
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
        if longPressedTag == b.tag { longPressedTag = nil; return }
        onSelect?(b.tag)
    }

    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let b = g.view as? UIButton else { return }
        longPressedTag = b.tag
        onLongPress?(b.tag)
    }
}
