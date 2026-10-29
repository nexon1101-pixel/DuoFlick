# DuoFlick

iPhone Duo の外側画面で打ちやすいフリック入力キーボードを作るためのプロジェクトです。
キーボードの ⚙ ボタンから、形（標準・右寄せ・扇形）や大きさを実機で調整できます。

Mac も有料の Apple Developer Program も使わずに、次の流れで iPhone に入れます。

1. GitHub に変更を送ると、GitHub Actions が Mac 上でアプリをビルドする（署名なし）
2. できた `DuoFlick.ipa` を Windows の PC にダウンロードする
3. Sideloadly で、無料の Apple ID を使って署名し、iPhone に入れる

## 初回だけの準備

### Windows の PC

1. Apple の「Apple Devices」アプリ（または iTunes）を入れる。iPhone を USB でつないだとき PC が認識するために必要です
2. [Sideloadly](https://sideloadly.io/) を入れる

### iPhone

1. 「設定」→「プライバシーとセキュリティ」→「デベロッパモード」をオンにする（iPhone を PC につないで一度 Sideloadly でインストールを試すと、この項目が表示されます）

## ビルドしてインストールする

1. GitHub のこのリポジトリの「Actions」タブを開き、左の「build」→ 右の「Run workflow」→「Run workflow」を押す。一番上の実行が緑のチェックになるまで待つ（初回は辞書の取得で10分前後）
2. その実行を開き、下の「Artifacts」にある `DuoFlick-ipa` をダウンロードして展開する
3. iPhone を USB で PC につなぎ、Sideloadly を開く
4. `DuoFlick.ipa` を Sideloadly にドラッグし、Apple ID を入力して「Start」を押す
5. iPhone で「設定」→「一般」→「VPNとデバイス管理」を開き、自分の Apple ID を「信頼」する（初回のみ）

## キーボードを使う

1. 「設定」→「一般」→「キーボード」→「キーボード」→「新しいキーボードを追加」で DuoFlick を追加する
2. 文字を入力できる場所で地球儀ボタンを長押しし、DuoFlick を選ぶ
3. 左列の ⚙ を押すと調整バーが出る。形を切り替えたり、項目を選んでスライダーで数値を変えたりすると、すぐに反映される

## 無料の Apple ID で使うときの注意

- 7日で署名が切れて起動しなくなります。Sideloadly の自動更新を有効にし、PC を起動して iPhone と同じ Wi-Fi につないでおくと、自動で入れ直されます
- 自作アプリは同時に3つまでしか入れられません

## キーボードの操作

- 空白キーを長押しして左右に動かすと、入力位置（カーソル）が動く
- 入力したひらがなは上の帯に変換候補が出る。候補をタップで確定、空白キーで次の候補、改行で確定
- 絵文字は 🌐 でiOSの絵文字キーボードに切り替える。変換候補にも絵文字が出る（例：わらう）
- ⚙ の調整バーで「比べて決める」を押すと、AとBの2つの値を打ち比べて、選んだほうへ少しずつ絞り込める

## 今の段階でできないこと

- 英字・数字の入力

## ライセンス

- かな漢字変換：[AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter)（MIT License）
- 辞書データ：[azooKey_dictionary_storage](https://github.com/ensan-hcl/azooKey_dictionary_storage)（Apache License 2.0）
