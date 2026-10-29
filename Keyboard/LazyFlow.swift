import SwiftUI
import UIKit

/// 文字を横に詰めて並べ、はみ出したら次の行へ送る。見えている行だけ作るので、候補が多くても軽い。
/// 行の余りは各項目で均等に分けて、端を揃える。
struct LazyFlow<Cell: View>: View {
    struct Slot { let index: Int; let width: CGFloat }

    let items: [String]
    let font: UIFont
    let hPad: CGFloat
    let minWidth: CGFloat
    let rowHeight: CGFloat
    let cell: (Int, String) -> Cell

    var body: some View {
        GeometryReader { geo in
            let rows = pack(width: geo.size.width)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows.indices, id: \.self) { r in
                        HStack(spacing: 0) {
                            ForEach(rows[r], id: \.index) { slot in
                                cell(slot.index, items[slot.index])
                                    .frame(width: slot.width, height: rowHeight)
                            }
                        }
                    }
                }
            }
        }
    }

    private func pack(width: CGFloat) -> [[Slot]] {
        guard width > 0 else { return [] }
        var rows: [[Slot]] = []
        var row: [Slot] = []
        var x: CGFloat = 0
        func flush() {
            guard !row.isEmpty else { return }
            let extra = max(0, width - x) / CGFloat(row.count)
            rows.append(row.map { Slot(index: $0.index, width: $0.width + extra) })
            row = []
            x = 0
        }
        for (i, text) in items.enumerated() {
            let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
            let w = min(width, max(minWidth, ceil(textWidth) + 2 * hPad))
            if x + w > width { flush() }
            row.append(Slot(index: i, width: w))
            x += w
        }
        flush()
        return rows
    }
}
