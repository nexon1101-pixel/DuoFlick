import SwiftUI

/// 単語登録の画面。単語は入力欄で選んだ文字（または直前に確定した文字）、読みは下のかなキーで入力する。
struct RegisterPanel: View {
    @ObservedObject var model: RegisterModel
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("単語登録").font(.footnote.weight(.semibold))
                Spacer()
                Button("やめる", action: onCancel).font(.footnote)
                Button("登録", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.word.isEmpty || model.reading.isEmpty)
            }
            if model.word.isEmpty {
                Text("登録したい単語を入力欄で選択してから、もう一度「単語登録」を開いてください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                row("単語", model.word, placeholder: "")
                row("読み", model.reading, placeholder: "下のキーで読みを入力（ひらがな）")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func row(_ title: String, _ value: String, placeholder: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 32, alignment: .leading)
            Text(value.isEmpty ? placeholder : value)
                .font(.body)
                .foregroundStyle(value.isEmpty ? Color.secondary : Color.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(uiColor: .secondarySystemBackground)))
        }
    }
}
