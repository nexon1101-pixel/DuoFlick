import SwiftUI

struct EmojiCategory: Identifiable {
    let id: String
    let icon: String
    let emojis: [String]
}

enum EmojiData {
    private static func scalars(_ ranges: [ClosedRange<UInt32>]) -> [String] {
        var out: [String] = []
        for r in ranges {
            for v in r {
                guard let u = Unicode.Scalar(v), u.properties.isEmojiPresentation else { continue }
                out.append(String(Character(u)))
            }
        }
        return out
    }

    static let categories: [EmojiCategory] = [
        EmojiCategory(id: "face", icon: "😀", emojis: scalars([0x1F600...0x1F64F, 0x1F910...0x1F92F, 0x1F970...0x1F97F])),
        EmojiCategory(id: "hand", icon: "👍", emojis: scalars([0x1F440...0x1F4AF, 0x1F930...0x1F94F, 0x1F9B0...0x1F9FF])),
        EmojiCategory(id: "nature", icon: "🌸", emojis: scalars([0x1F300...0x1F37F, 0x1F400...0x1F43F])),
        EmojiCategory(id: "thing", icon: "⚽", emojis: scalars([0x1F380...0x1F3FF, 0x1F4B0...0x1F5FF, 0x1F680...0x1F6FF])),
        EmojiCategory(id: "symbol", icon: "❤", emojis: scalars([0x2600...0x27BF, 0x1F950...0x1F96F, 0x1F980...0x1F9AF, 0x1FA70...0x1FAFF])),
    ]
}

final class EmojiRecents: ObservableObject {
    private static let key = "DuoFlick.emojiRecents.v1"
    @Published private(set) var items: [String] = UserDefaults.standard.stringArray(forKey: EmojiRecents.key) ?? []

    func use(_ e: String) {
        var list = items.filter { $0 != e }
        list.insert(e, at: 0)
        items = Array(list.prefix(32))
        UserDefaults.standard.set(items, forKey: Self.key)
    }
}

/// キーボードの代わりに表示する絵文字の一覧
struct EmojiPanel: View {
    @StateObject private var recents = EmojiRecents()
    @State private var selected = "recent"
    let onInsert: (String) -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    private var emojis: [String] {
        if selected == "recent" { return recents.items }
        return EmojiData.categories.first { $0.id == selected }?.emojis ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                if emojis.isEmpty {
                    Text("最近使った絵文字はまだありません")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 24)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 8), spacing: 4) {
                    ForEach(emojis, id: \.self) { e in
                        Button {
                            recents.use(e)
                            onInsert(e)
                        } label: {
                            Text(e).font(.system(size: 28)).frame(maxWidth: .infinity, minHeight: 40)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 6)
            }
            HStack(spacing: 4) {
                Button(action: onClose) {
                    Text("あいう").font(.system(size: 15, weight: .medium)).frame(width: 56, height: 36)
                }
                .buttonStyle(.bordered)
                tab("recent", "🕘")
                ForEach(EmojiData.categories) { c in tab(c.id, c.icon) }
                Button(action: onDelete) {
                    Image(systemName: "delete.left").frame(width: 40, height: 36)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
    }

    private func tab(_ id: String, _ icon: String) -> some View {
        Button { selected = id } label: {
            Text(icon)
                .font(.system(size: 20))
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(selected == id ? Color.accentColor.opacity(0.35) : Color.clear))
        }
        .buttonStyle(.plain)
    }
}
