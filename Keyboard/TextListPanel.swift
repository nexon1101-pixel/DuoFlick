import SwiftUI

/// 定型文・クリップボード履歴を選ぶ画面。キーボードに重ねて表示する。
struct TextListPanel: View {
    let title: String
    @ObservedObject var store: TextListStore
    let emptyMessage: String
    let notice: String?
    let addTitle: String?
    let onAdd: (() -> Void)?
    let secondaryTitle: String?
    let onSecondary: ((String) -> Void)?
    let onSelect: (String) -> Void
    let onClose: () -> Void

    @State private var editing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                if let addTitle, let onAdd {
                    Button(addTitle, action: onAdd).font(.footnote)
                }
                if !store.items.isEmpty {
                    if editing {
                        Button("固定以外を消す") { store.removeAll() }.font(.footnote)
                    }
                    Button(editing ? "完了" : "編集") { editing.toggle() }.font(.footnote)
                }
                Button("閉じる", action: onClose)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
            if store.items.isEmpty {
                Text(emptyMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(store.items.enumerated()), id: \.offset) { i, text in
                            HStack(spacing: 8) {
                                Button { onSelect(text) } label: {
                                    HStack(spacing: 6) {
                                        if store.pinned.contains(text) {
                                            Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
                                        }
                                        Text(text)
                                        .font(.body)
                                        .lineLimit(2)
                                    }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: Palette.key)))
                                        .foregroundStyle(Color(uiColor: Palette.text))
                                }
                                .buttonStyle(.plain)
                                .disabled(editing)
                                if editing {
                                    Button(store.pinned.contains(text) ? "固定を外す" : "固定") { store.togglePin(text) }
                                        .font(.caption)
                                    if let secondaryTitle, let onSecondary {
                                        Button(secondaryTitle) { onSecondary(text) }.font(.caption)
                                    }
                                    Button(role: .destructive) { store.remove(at: i) } label: {
                                        Image(systemName: "trash")
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
        }
        .background(Color(uiColor: Palette.background))
    }
}
