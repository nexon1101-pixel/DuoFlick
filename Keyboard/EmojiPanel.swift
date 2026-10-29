import SwiftUI

/// 絵文字の一覧。iOS の文字データ（Unicode の絵文字の印）から自動で作る。種類の分け方はおおまかなもの
enum EmojiData {
    struct Category: Identifiable {
        let id: String
        let ranges: [ClosedRange<UInt32>]
        var emojis: [String] = []
    }

    /// 先に書いたものから順に、当てはまる種類に入れる（残りは「記号」）
    static let categories: [Category] = {
        var cats: [Category] = [
            Category(id: "顔", ranges: [0x1F600...0x1F64F, 0x1F910...0x1F92F, 0x1F970...0x1F97F, 0x1FAE0...0x1FAEF]),
            Category(id: "人", ranges: [0x1F440...0x1F4AF, 0x1F90C...0x1F90F, 0x1F930...0x1F93F, 0x1F9B0...0x1F9BF, 0x1F9D0...0x1F9DF, 0x1F6B6...0x1F6C0]),
            Category(id: "自然", ranges: [0x1F300...0x1F32F, 0x1F400...0x1F43F, 0x1F980...0x1F9AF, 0x1FAB0...0x1FABF]),
            Category(id: "食べ物", ranges: [0x1F330...0x1F37F, 0x1F950...0x1F96F, 0x1F9C0...0x1F9CF, 0x1FAD0...0x1FADF]),
            Category(id: "乗り物", ranges: [0x1F680...0x1F6FF, 0x1F3A0...0x1F3FF, 0x1F4B0...0x1F4FF, 0x1F500...0x1F5FF]),
            Category(id: "記号", ranges: [0x0000...0x1FFFF]),
        ]
        for v in UInt32(0x203C)...UInt32(0x1FAFF) {
            guard let s = Unicode.Scalar(v), s.properties.isEmoji, v > 0xFF else { continue }
            // 肌の色の印や、国旗用の文字は単独では出さない
            if (0x1F3FB...0x1F3FF).contains(v) || (0x1F1E6...0x1F1FF).contains(v) { continue }
            var text = String(s)
            if !s.properties.isEmojiPresentation { text += "\u{FE0F}" }
            if let i = cats.firstIndex(where: { c in c.ranges.contains { $0.contains(v) } }) {
                cats[i].emojis.append(text)
            }
        }
        return cats.filter { !$0.emojis.isEmpty }
    }()
}

struct EmojiPanel: View {
    let onSelect: (String) -> Void
    let onClose: () -> Void
    @State private var selected = 0

    var body: some View {
        let cats = EmojiData.categories
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(cats.enumerated()), id: \.offset) { i, c in
                            Button { selected = i } label: {
                                Text(c.id)
                                    .font(.system(size: 15))
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .foregroundStyle(Color(uiColor: selected == i ? Palette.pressedText : Palette.text))
                                    .background(selected == i ? Color(uiColor: Palette.pressed) : Color.clear)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .foregroundStyle(Color(uiColor: Palette.text))
                        .frame(width: 48, height: 40)
                }
                .buttonStyle(.plain)
            }
            .frame(height: 44)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: 0)], spacing: 0) {
                    ForEach(Array((cats.indices.contains(selected) ? cats[selected].emojis : []).enumerated()), id: \.offset) { _, e in
                        Button { onSelect(e) } label: {
                            Text(e).font(.system(size: 30)).frame(width: 46, height: 46)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
    }
}
