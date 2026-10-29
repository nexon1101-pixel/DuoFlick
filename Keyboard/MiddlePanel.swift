import SwiftUI

/// iOS標準の配置で、真ん中に出す変換候補の一覧（縦に並べて、細い線で区切る）
final class PanelModel: ObservableObject {
    @Published var items: [String] = []
    @Published var selected: Int?
}

struct MiddlePanel: View {
    @ObservedObject var model: PanelModel
    let onSelect: (Int) -> Void
    var onSwipeDown: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            FlowRows(spacing: 0) {
                ForEach(Array(model.items.enumerated()), id: \.offset) { i, text in
                    Button { onSelect(i) } label: {
                        Text(text)
                            .font(.system(size: 20))
                            .lineLimit(1)
                            .foregroundStyle(Color(uiColor: model.selected == i ? Palette.pressedText : Palette.text))
                            .padding(.horizontal, 12)
                            .frame(minWidth: 52, minHeight: 44)
                            .background(model.selected == i ? Color(uiColor: Palette.pressed) : Color.clear)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 0.5)
                    }
                }
            }
        }
        // 下に素早くフリックしたら、キーボードを閉じる
        .simultaneousGesture(
            DragGesture(minimumDistance: 24).onEnded { v in
                if v.translation.height > 60, abs(v.translation.width) < v.translation.height / 2,
                   v.predictedEndTranslation.height > 200 {
                    onSwipeDown?()
                }
            }
        )
        .background(Color.gray.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
