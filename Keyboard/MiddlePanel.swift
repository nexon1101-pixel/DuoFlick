import SwiftUI

/// iOS標準の配置で、真ん中に出す変換候補の一覧（縦に並べて、細い線で区切る）
final class PanelModel: ObservableObject {
    @Published var items: [String] = []
    @Published var selected: Int?
    /// ライブ変換で、打った読みを小さく出す
    @Published var reading: String = ""
    /// 長押しが成立した項目番号。その直後の通常選択は1回だけ飲み込む
    var suppressSelect: Int?
}

struct MiddlePanel: View {
    @ObservedObject var model: PanelModel
    let onSelect: (Int) -> Void
    var onSwipeDown: (() -> Void)? = nil
    var onReading: (() -> Void)? = nil
    /// 範囲選択：長押しで入り、そのまま横ドラッグで範囲を伸縮し、離して決める
    var onRangeEnter: ((Int) -> Void)? = nil
    var onRangeDrag: ((CGFloat) -> Void)? = nil
    var onRangeEnded: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            if !model.reading.isEmpty, !model.items.isEmpty {
                HStack {
                    Button { onReading?() } label: {
                        Text(model.reading)
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .foregroundStyle(Color(uiColor: Palette.text).opacity(0.7))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.gray.opacity(0.3)))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)
            }
            list
        }
        .id(model.items.isEmpty)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeOut(duration: 0.18), value: model.items.isEmpty)
        .background(Color.gray.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        // 下にフリックしたら、キーボードを閉じる（候補が少なくて空きができても、エリア全体で受ける）
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 16).onEnded { v in
                if v.translation.height > 36, abs(v.translation.width) < v.translation.height / 1.5 {
                    onSwipeDown?()
                }
            }
        )
    }

    private var list: some View {
        LazyFlow(items: model.items, font: .systemFont(ofSize: 20), hPad: 12, minWidth: 52, rowHeight: 44) { i, text in
            Button { onSelect(i) } label: {
                Text(text)
                    .font(.system(size: 20))
                    .lineLimit(1)
                    .foregroundStyle(Color(uiColor: model.selected == i ? Palette.pressedText : Palette.text))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(model.selected == i ? Color(uiColor: Palette.pressed) : Color.clear)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .gesture(LongPressGesture(minimumDuration: 0.4).sequenced(before: DragGesture(minimumDistance: 0))
                .onChanged { value in
                    switch value {
                    case .first(true):
                        model.suppressSelect = i
                        onRangeEnter?(i)
                    case .second(_, let drag?):
                        onRangeDrag?(drag.translation.width)
                    default:
                        break
                    }
                }
                .onEnded { _ in onRangeEnded?() })
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 0.5)
            }
        }
    }
}
