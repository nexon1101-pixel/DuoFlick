import SwiftUI

/// アプリ本体の設定画面。変更したら「キーボードに反映」を押す（クリップボード経由で、次にキーボードを開いたときに読み込まれる）
struct AppSettingsScreen: View {
    @State private var prefs: SharedPrefs = {
        if let data = SharedStore.defaults.data(forKey: "DuoFlick.app.prefs.v1"),
           let p = try? JSONDecoder().decode(SharedPrefs.self, from: data) { return p }
        return SharedPrefs()
    }()
    @State private var copied = false

    var body: some View {
        Form {
            Section("配置") {
                Toggle("内側画面の片手持ちをiOS標準の配置にする", isOn: $prefs.iosLayout)
                VStack(alignment: .leading) {
                    Text("キーの文字の大きさ　\(Int(prefs.labelScale * 100))%")
                    Slider(value: $prefs.labelScale, in: 0.7...1.5, step: 0.05)
                }
            }
            Section("入力") {
                Toggle("続けてタップで文字を切り替え", isOn: $prefs.toggleTap)
                Toggle("ずれ補正（押す位置と斜めのくせ）", isOn: $prefs.autoCorrect)
                Toggle("変換待ちの間は、ABC・地球儀など入力を中断するキーを止める", isOn: $prefs.lockWhileComposing)
                Toggle("キーを押したときの振動", isOn: $prefs.haptics)
            }
            Section("変換") {
                Toggle("打ち間違いの候補（試験的）", isOn: $prefs.typoCorrection)
            }
            Section {
                Button(copied ? "コピーしました" : "キーボードに反映する") {
                    UIPasteboard.general.string = prefs.encoded()
                    copied = true
                }
                Text("押すと設定がクリップボードにコピーされます。そのあと、どこかの入力欄でDuoFlickを開くと、自動で読み込まれます（フルアクセスが必要です）。形や大きさなど、細かい調整は、今までどおりキーボードの地球儀キーを上にフリックして開く設定で行います。")
                    .font(.footnote)
            }
        }
        .navigationTitle("設定")
        .onChange(of: prefs) { _, new in
            copied = false
            if let data = try? JSONEncoder().encode(new) {
                SharedStore.defaults.set(data, forKey: "DuoFlick.app.prefs.v1")
            }
        }
    }
}
