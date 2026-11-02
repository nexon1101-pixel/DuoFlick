import UIKit

/// 候補の一覧（候補の帯の∨で開く）を、UIKit の UICollectionView で出す。
/// SwiftUI の CandidateList / LazyFlow の代わり。セルを使い回すので、
/// 120件あっても開くとき・スクロール中のレイアウト計算が軽い。
/// 一覧自体は作り直さず使い回し、開閉は isHidden の切り替えで行う。
/// フェードは見た目だけ残し、タップはフェード中も通るようにする
/// （呼び出し側で .allowUserInteraction を付けてアニメーションする）。
final class CandidateListView: UIView {
    static let rowHeight: CGFloat = 46
    static let fontSize: CGFloat = 20
    static let hPad: CGFloat = 14
    static let minWidth: CGFloat = 52

    var onSelect: ((Int) -> Void)?

    private(set) var items: [String] = []

    private let layout = CandidateFlowLayout()
    private lazy var collectionView: UICollectionView = {
        let v = UICollectionView(frame: .zero, collectionViewLayout: self.layout)
        v.backgroundColor = .clear
        v.alwaysBounceVertical = true
        v.isPrefetchingEnabled = true
        // タップの反応を遅らせない。スクロールとの判別は
        // UICollectionView がタッチのキャンセルで処理する。
        v.delaysContentTouches = false
        v.translatesAutoresizingMaskIntoConstraints = false
        v.register(CandidateCell.self, forCellWithReuseIdentifier: CandidateCell.reuseID)
        v.dataSource = self
        v.delegate = self
        return v
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 候補を入れ替える。同じ内容なら何もしない（再描画・スクロール位置の
    /// リセットを避けるため）。変わったときは先頭に戻す。
    /// - Returns: 内容が変わったかどうか
    @discardableResult
    func setItems(_ newItems: [String]) -> Bool {
        guard newItems != items else { return false }
        items = newItems
        layout.items = newItems
        collectionView.reloadData()
        collectionView.setContentOffset(.zero, animated: false)
        return true
    }
}

extension CandidateListView: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: CandidateCell.reuseID, for: indexPath) as? CandidateCell else {
            return UICollectionViewCell()
        }
        cell.configure(items[indexPath.item])
        return cell
    }
}

extension CandidateListView: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        onSelect?(indexPath.item)
    }
}

/// 候補を横に詰めて並べ、はみ出したら次の行へ送るレイアウト。
/// 行の余りは各項目で均等に分けて端を揃える（LazyFlow と同じ見た目）。
/// 項目の枠は prepare() で一度だけ計算し、キャッシュする。
/// 幅が変わったときだけ計算し直す。
final class CandidateFlowLayout: UICollectionViewLayout {
    var items: [String] = []

    private var frames: [CGRect] = []
    private var contentHeightValue: CGFloat = 0
    private var cachedWidth: CGFloat = 0
    private var cachedItems: [String] = []

    private let font = UIFont.systemFont(ofSize: CandidateListView.fontSize)

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let width = collectionView.bounds.width
        guard width > 0 else { return }
        // 幅も内容も同じなら、計算し直さない。
        if width == cachedWidth, items == cachedItems, !frames.isEmpty { return }
        cachedWidth = width
        cachedItems = items
        frames = []
        var rows: [[Int]] = []
        var rowWidths: [CGFloat] = []
        var row: [Int] = []
        var x: CGFloat = 0
        for (i, text) in items.enumerated() {
            let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
            let w = min(width, max(CandidateListView.minWidth, ceil(textWidth) + 2 * CandidateListView.hPad))
            if x + w > width, !row.isEmpty {
                rows.append(row)
                rowWidths.append(x)
                row = []
                x = 0
            }
            row.append(i)
            // 枠の幅はここでは仮に測った幅で持ち、行が決まったら余りを足す。
            // 枠そのものは下で作り直すため、ここでは幅の合計だけ見る。
            // （幅の記録は frames ではなく、別に保持する）
            x += w
            // 幅をあとで使えるよう、frames に仮の枠を入れておく。
            // 行が確定したら、同じ行の枠の幅を余りぶんだけ広げる。
            frames.append(CGRect(x: 0, y: 0, width: w, height: CandidateListView.rowHeight))
        }
        if !row.isEmpty {
            rows.append(row)
            rowWidths.append(x)
        }
        // 行ごとに、余りを各項目で均等に分けて枠を作り直す。
        var y: CGFloat = 0
        for (r, indices) in rows.enumerated() {
            let used = rowWidths[r]
            let extra = indices.isEmpty ? 0 : max(0, width - used) / CGFloat(indices.count)
            var rx: CGFloat = 0
            for i in indices {
                let w = frames[i].width + extra
                frames[i] = CGRect(x: rx, y: y, width: w, height: CandidateListView.rowHeight)
                rx += w
            }
            y += CandidateListView.rowHeight
        }
        contentHeightValue = y
    }

    override var collectionViewContentSize: CGSize {
        guard let collectionView else { return .zero }
        return CGSize(width: collectionView.bounds.width, height: contentHeightValue)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        var out: [UICollectionViewLayoutAttributes] = []
        for (i, frame) in frames.enumerated() where frame.intersects(rect) {
            let attr = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: i, section: 0))
            attr.frame = frame
            out.append(attr)
        }
        return out
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.item < frames.count else { return nil }
        let attr = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attr.frame = frames[indexPath.item]
        return attr
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let collectionView else { return false }
        return newBounds.width != collectionView.bounds.width
    }

    override func invalidateLayout() {
        // 幅が変わっていないときの prepare() での早期リターンのため、
        // ここではキャッシュを消さない。内容や幅が変わったときに
        // prepare() が計算し直す。
        super.invalidateLayout()
    }
}

/// 候補1件のセル。文字と、右・下の細い区切り線だけの軽い構成。
final class CandidateCell: UICollectionViewCell {
    static let reuseID = "CandidateCell"

    private let label = UILabel()
    private let rightLine = UIView()
    private let bottomLine = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        label.font = UIFont.systemFont(ofSize: CandidateListView.fontSize)
        label.textColor = Palette.text
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        rightLine.backgroundColor = UIColor.secondary.withAlphaComponent(0.25)
        rightLine.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rightLine)
        bottomLine.backgroundColor = UIColor.secondary.withAlphaComponent(0.25)
        bottomLine.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bottomLine)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            label.topAnchor.constraint(equalTo: contentView.topAnchor),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            rightLine.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rightLine.widthAnchor.constraint(equalToConstant: 0.5),
            rightLine.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            rightLine.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            bottomLine.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bottomLine.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            bottomLine.heightAnchor.constraint(equalToConstant: 0.5),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        label.text = nil
    }

    func configure(_ text: String) {
        label.text = text
    }
}
