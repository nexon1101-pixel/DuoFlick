import SwiftUI

@main
struct DuoFlickApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("はじめに") {
                    Text("1. 設定アプリで「一般」→「キーボード」→「キーボード」→「新しいキーボードを追加」を開き、DuoFlick を追加します。")
                    Text("2. 下の入力欄をタップし、地球儀ボタンを長押しして DuoFlick を選びます。")
                    Text("3. キーボード左側の ⚙ ボタンで、形・大きさ・位置を調整できます。変更はすぐに反映されます。")
                    Button("設定アプリを開く") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
                Section("試し打ち") {
                    TextEditor(text: $text)
                        .frame(minHeight: 160)
                    Button("入力欄を消去", role: .destructive) { text = "" }
                }
                Section("ライセンス") {
                    Text("かな漢字変換に AzooKeyKanaKanjiConverter（MIT License, Copyright (c) 2023 Miwa / Ensan）と azooKey の辞書データ（Apache License 2.0）を使っています。")
                        .font(.footnote)
                }
            }
            .navigationTitle("DuoFlick")
        }
    }
}
