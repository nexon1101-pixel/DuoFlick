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
    @State private var showTutorial = false
    private static let tutorialKey = "DuoFlick.app.tutorialSeen.v1"

    var body: some View {
        NavigationStack {
            Form {
                Section("はじめに") {
                    Text("1. 設定アプリで「一般」→「キーボード」→「キーボード」→「新しいキーボードを追加」を開き、DuoFlick を追加します。")
                    Text("2. 下の入力欄をタップし、地球儀ボタンを長押しして DuoFlick を選びます。")
                    Text("3. 形・大きさ・位置などの設定は、下の「設定を開く」で、キーボードを見ながら変えられます。変えた設定は、次にキーボードを開いたときに反映されます。")
                    Button("設定アプリを開く") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
                Section("使い方") {
                    Button("はじめに（チュートリアル）") { showTutorial = true }
                }
                Section("設定") {
                    NavigationLink("設定を開く") { DesignScreen() }
                }
                Section("共有の状態") {
                    Text("キーボードとの設定の共有：\(SharedStore.statusText)")
                    if let id = SharedStore.groupID {
                        Text(id).font(.footnote).foregroundStyle(.secondary)
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
            .onAppear {
                // 最初の起動だけ、チュートリアルを出す
                if !SharedStore.defaults.bool(forKey: Self.tutorialKey) { showTutorial = true }
            }
            .fullScreenCover(isPresented: $showTutorial) {
                TutorialScreen {
                    SharedStore.defaults.set(true, forKey: Self.tutorialKey)
                    showTutorial = false
                }
            }
        }
    }
}
