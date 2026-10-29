import UIKit

/// キーボード上部の変換候補の帯。横にスクロールできる。
final class CandidateBar: UIView {
    static let height: CGFloat = 44

    var onSelect: ((Int) -> Void)?

    private let scroll = UIScrollView()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        stack.axis = .horizontal
        stack.spacing = 4
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
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

    /// 帯に並べる候補の上限（多すぎると重くなるため）
    static let maxItems = 30

    func show(_ items: [String], selected: Int?) {
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
        if let s = selected, s < stack.arrangedSubviews.count {
            layoutIfNeeded()
            scroll.scrollRectToVisible(stack.arrangedSubviews[s].frame.insetBy(dx: -40, dy: 0), animated: true)
        } else {
            scroll.setContentOffset(.zero, animated: false)
        }
    }

    @objc private func tapped(_ b: UIButton) {
        onSelect?(b.tag)
    }
}
