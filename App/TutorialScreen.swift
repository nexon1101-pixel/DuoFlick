import SwiftUI

/// はじめに見る、順番に進む使い方ガイド。初回の起動で出し、あとからホームでも開ける。
struct TutorialScreen: View {
    let onClose: () -> Void
    @State private var index = 0
    @State private var trial = ""

    private struct Page {
        let symbol: String
        let title: String
        let lines: [String]
        var button: String? = nil
        var isTrial = false
    }

    private let pages: [Page] = [
        Page(symbol: "keyboard", title: "DuoFlick へようこそ",
             lines: ["iPhone Duo で打ちやすいように作った、日本語のフリックキーボードです。",
                     "はじめに、キーボードを使えるようにします。4つの画面で説明します。"]),
        Page(symbol: "plus.rectangle.on.rectangle", title: "1. キーボードを追加する",
             lines: ["設定アプリを開き、「一般」→「キーボード」→「キーボード」→「新しいキーボードを追加」を選びます。",
                     "一覧から DuoFlick を選んで追加します。"],
             button: "設定アプリを開く"),
        Page(symbol: "lock.open", title: "2. フルアクセスを許可する",
             lines: ["追加した DuoFlick をタップし、「フルアクセスを許可」をオンにします。",
                     "振動、貼り付け、クリップボードの履歴、アプリの設定をキーボードへ渡す機能に使います。",
                     "入力した内容を外へ送る処理は入れていません。"],
             button: "設定アプリを開く"),
        Page(symbol: "globe", title: "3. キーボードを切り替える",
             lines: ["文字を入れる場所をタップして、キーボードの地球儀キーを押すと、DuoFlick に切り替わります。",
                     "DuoFlick の地球儀キーは、押した方向で働きが変わります。",
                     "タップ：次のキーボード　上：設定　右：クリップボードの履歴　下：定型文"]),
        Page(symbol: "hand.draw", title: "4. フリックで打つ",
             lines: ["キーを押すと、まわりに文字が出ます。押したまま上下左右へ動かして離すと、その文字が入ります。",
                     "変換の候補は、上の帯に出ます。タップして選ぶか、空白で次の候補、改行で確定です。",
                     "数字は、「123」のキーを押したまま少し動かすと、かなキーが電話の配置の数字になります。離した位置のキーの数字が入ります。2回続けてタップすると数字が固定されます。"]),
        Page(symbol: "slider.horizontal.3", title: "5. 設定を調整する",
             lines: ["Duo を開いた状態で、ホームの「設定を開く」を選びます。",
                     "上のキーボードを見ながら、形や大きさを調整します。動かしても、すぐにはキーボードへ反映されません。",
                     "変えた内容は、画面下の「保存して反映」を押すと、キーボードへ渡ります。保存していない変更は、点線で保存済みの位置が見えます。"]),
        Page(symbol: "square.and.pencil", title: "試し打ち",
             lines: ["下の欄をタップして、地球儀キーで DuoFlick に切り替え、打ってみてください。"],
             isTrial: true),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(index == pages.count - 1 ? "閉じる" : "スキップ", action: onClose)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
            ScrollView {
                let page = pages[index]
                VStack(spacing: 16) {
                    Image(systemName: page.symbol)
                        .font(.system(size: 52))
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 16)
                    Text(page.title)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(page.lines, id: \.self) { Text($0).font(.body) }
                    }
                    if let b = page.button {
                        Button(b) {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    if page.isTrial {
                        TextEditor(text: $trial)
                            .frame(height: 120)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .secondarySystemBackground)))
                    }
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
            }
            HStack(spacing: 6) {
                ForEach(pages.indices, id: \.self) { i in
                    Circle()
                        .fill(i == index ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.top, 8)
            HStack(spacing: 12) {
                Button("戻る") { index -= 1 }
                    .buttonStyle(.bordered)
                    .disabled(index == 0)
                Button(index == pages.count - 1 ? "完了" : "次へ") {
                    if index == pages.count - 1 { onClose() } else { index += 1 }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 14)
        }
        .background(Color(uiColor: .systemBackground))
    }
}
