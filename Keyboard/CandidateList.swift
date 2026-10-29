import SwiftUI

/// 候補の一覧（候補の帯の∨で開く）。キーボードの部分に重ねて表示する。
struct CandidateList: View {
    let items: [String]
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)], spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, text in
                    Button { onSelect(i) } label: {
                        Text(text)
                            .font(.system(size: 19))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: Palette.key)))
                            .foregroundStyle(Color(uiColor: Palette.text))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
        .background(Color(uiColor: Palette.background))
    }
}
