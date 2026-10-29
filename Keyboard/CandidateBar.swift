import UIKit

/// キーボード上部の変換候補の帯。横にスクロールできる。
final class CandidateBar: UIView {
    static let height: CGFloat = 44

    var onSelect: ((Int) -> Void)?
    /// 候補がないときに出す道具ボタン
    var onTool: ((String) -> Void)?
    private var toolIDs: [String] = []

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

    func show(_ items: [String], selected: Int?) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, text) in items.enumerated() {
            var config = UIButton.Configuration.plain()
            var title = AttributedString(text)
            title.font = UIFont.systemFont(ofSize: 19)
            config.attributedTitle = title
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
            config.baseForegroundColor = i == selected ? Palette.pressedText : Palette.text
            config.background.backgroundColor = i == selected ? Palette.pressed : .clear
            config.background.cornerRadius = 8
            let b = UIButton(configuration: config)
            b.tag = i
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

    struct Tool {
        let id: String
        let title: String
        let on: Bool
    }

    /// 変換候補がないときは、片手・両手の切り替えなどの道具を並べる
    func showTools(_ tools: [Tool]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        toolIDs = tools.map(\.id)
        for (i, t) in tools.enumerated() {
            var config = UIButton.Configuration.plain()
            var title = AttributedString(t.title)
            title.font = UIFont.systemFont(ofSize: 14, weight: .medium)
            config.attributedTitle = title
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
            config.baseForegroundColor = t.on ? Palette.pressedText : Palette.text
            config.background.backgroundColor = t.on ? Palette.pressed : Palette.functionKey.withAlphaComponent(0.6)
            config.background.cornerRadius = 14
            let b = UIButton(configuration: config)
            b.tag = i
            b.addTarget(self, action: #selector(toolTapped(_:)), for: .touchUpInside)
            stack.addArrangedSubview(b)
        }
        scroll.setContentOffset(.zero, animated: false)
    }

    @objc private func toolTapped(_ b: UIButton) {
        guard b.tag < toolIDs.count else { return }
        onTool?(toolIDs[b.tag])
    }
}
