import SwiftUI

/// 候補の一覧（候補の帯の∨で開く）。iPhone標準のように、文字を横に詰めて並べ、細い線で区切る。
struct CandidateList: View {
    let items: [String]
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollView {
            FlowRows(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, text in
                    Button { onSelect(i) } label: {
                        Text(text)
                            .font(.system(size: 20))
                            .lineLimit(1)
                            .foregroundStyle(Color(uiColor: Palette.text))
                            .padding(.horizontal, 14)
                            .frame(minWidth: 52, minHeight: 46)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 0.5).padding(.vertical, 10)
                    }
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 0.5)
                    }
                }
            }
        }
        .background(Color(uiColor: Palette.background))
    }
}

/// 横に並べて、はみ出したら次の行に送るレイアウト。行の余りは各項目で均等に分けて端を揃える。
struct FlowRows: Layout {
    var spacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let rows = makeRows(width: width, subviews: subviews)
        let height = rows.reduce(CGFloat(0)) { $0 + $1.height }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = makeRows(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            let used = row.sizes.reduce(CGFloat(0)) { $0 + $1.width }
            let extra = row.indices.count > 0 ? max(0, bounds.width - used) / CGFloat(row.indices.count) : 0
            var x = bounds.minX
            for (k, i) in row.indices.enumerated() {
                let w = row.sizes[k].width + extra
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: w, height: row.height))
                x += w
            }
            y += row.height
        }
    }

    private struct Row {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var height: CGFloat = 0
    }

    private func makeRows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        var x: CGFloat = 0
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let w = min(size.width, width)
            if x + w > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
                x = 0
            }
            row.indices.append(i)
            row.sizes.append(CGSize(width: w, height: size.height))
            row.height = max(row.height, size.height)
            x += w
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
