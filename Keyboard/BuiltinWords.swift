import Foundation

/// 最初から入れておく、メジャーな製品名・サービス名・英語表記の単語（読み,単語）。
/// 変換エンジンの辞書に足りないものを補う。ユーザー辞書に同じ読みがあれば、そちらが優先される。
enum BuiltinWords {
    static let list: [(reading: String, word: String)] = raw.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: ",", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (reading: parts[0], word: parts[1])
    }

    private static let raw = """
    えあたぐ,AirTag
    えあたぐ,エアタグ
    えあぽっず,AirPods
    えあぽっつ,AirPods
    えあぽっず,エアポッズ
    えあぽっずぷろ,AirPods Pro
    えあどろっぷ,AirDrop
    えあぷれい,AirPlay
    えあぷりんと,AirPrint
    あいふぉん,iPhone
    あいぱっど,iPad
    あいまっく,iMac
    あいぽっど,iPod
    あいくらうど,iCloud
    あいめっせーじ,iMessage
    あいてぃーんず,iTunes
    あいおーえす,iOS
    あいぱっどおーえす,iPadOS
    まっくぶっく,MacBook
    まっくぶっくえあ,MacBook Air
    まっくぶっくぷろ,MacBook Pro
    まっくおーえす,macOS
    あっぷるうぉっち,Apple Watch
    あっぷる,Apple
    あっぷるぺんしる,Apple Pencil
    あっぷるぺい,Apple Pay
    あっぷるみゅーじっく,Apple Music
    あっぷるてぃーびー,Apple TV
    あっぷるけあ,AppleCare
    あっぷるけあぷらす,AppleCare+
    あっぷすとあ,App Store
    あっぷるすとあ,Apple Store
    ふぇいすたいむ,FaceTime
    ふぇいすあいでぃー,Face ID
    たっちあいでぃー,Touch ID
    あいでぃー,ID
    さふぁり,Safari
    しり,Siri
    えっくすこーど,Xcode
    すうぃふと,Swift
    すうぃふとゆーあい,SwiftUI
    ぐーぐる,Google
    ぐーぐるまっぷ,Google マップ
    ぐーぐるどらいぶ,Google ドライブ
    ぐーぐるかれんだー,Google カレンダー
    ぐーぐるどっくす,Google ドキュメント
    ぐーぐるすぷれっどしーと,Google スプレッドシート
    じーめーる,Gmail
    ぐーぐるくろーむ,Google Chrome
    くろーむ,Chrome
    あんどろいど,Android
    ぴくせる,Pixel
    ゆーちゅーぶ,YouTube
    ゆーちゅーばー,YouTuber
    ゆーちゅーぶみゅーじっく,YouTube Music
    ちゃっとじーぴーてぃー,ChatGPT
    じーぴーてぃー,GPT
    おーぷんえーあい,OpenAI
    くろーど,Claude
    あんすろぴっく,Anthropic
    じぇみに,Gemini
    こぱいろっと,Copilot
    ぱーぷれきしてぃ,Perplexity
    えーあい,AI
    らいん,LINE
    いんすたぐらむ,Instagram
    いんすた,Instagram
    ついったー,Twitter
    えっくす,X
    ふぇいすぶっく,Facebook
    てぃっくとっく,TikTok
    すれっず,Threads
    でぃすこーど,Discord
    すらっく,Slack
    ずーむ,Zoom
    ちーむず,Teams
    のーしょん,Notion
    ぎっとはぶ,GitHub
    ぎっと,Git
    ぎっとらぶ,GitLab
    どっかー,Docker
    くばーねてぃす,Kubernetes
    えーだぶりゅーえす,AWS
    あじゅーる,Azure
    ぱいそん,Python
    じゃばすくりぷと,JavaScript
    たいぷすくりぷと,TypeScript
    たいぷすくりぷと,TypeScript
    じゃば,Java
    ことりん,Kotlin
    らすと,Rust
    ごー,Go
    あーるえすえす,RSS
    ゔぃじゅあるすたじおこーど,Visual Studio Code
    ぶいえすこーど,VS Code
    うぃんどうず,Windows
    まいくろそふと,Microsoft
    おふぃす,Office
    えくせる,Excel
    わーど,Word
    ぱわーぽいんと,PowerPoint
    あうとるっく,Outlook
    わんどらいぶ,OneDrive
    あまぞん,Amazon
    あまぞんぷらいむ,Amazon Prime
    ぷらいむびでお,Prime Video
    ねっとふりっくす,Netflix
    でぃずにーぷらす,Disney+
    すぽてぃふぁい,Spotify
    らくてん,楽天
    ぺいぺい,PayPay
    めるかり,メルカリ
    すいか,Suica
    ぱすも,PASMO
    いこか,ICOCA
    えすえぬえす,SNS
    うぇぶ,Web
    うぇぶさいと,Webサイト
    ぶるーとぅーす,Bluetooth
    わいふぁい,Wi-Fi
    ゆーえすびー,USB
    ゆーえすびーしー,USB-C
    えすでぃーかーど,SDカード
    えすえすでぃー,SSD
    えいちでぃーでぃー,HDD
    えいちでぃーえむあい,HDMI
    ぴーでぃーえふ,PDF
    えぬえーえす,NAS
    ぶいぴーえぬ,VPN
    えいぴーあい,API
    ゆーあーるえる,URL
    えいちてぃーえむえる,HTML
    しーえすえす,CSS
    えすきゅーえる,SQL
    えぬえふしー,NFC
    ぎがばいと,GB
    めがばいと,MB
    じーぴーえす,GPS
    えすおーえす,SOS
    おーえるいーでぃー,OLED
    ぷれすて,PlayStation
    ぷれいすてーしょん,PlayStation
    すうぃっち,Switch
    にんてんどー,Nintendo
    えっくすぼっくす,Xbox
    すちーむ,Steam
    ぽけもん,ポケモン
    ぽけっともんすたー,ポケットモンスター
    てすら,Tesla
    とよた,トヨタ
    ほんだ,ホンダ
    ばっくえんど,バックエンド
    ふろんとえんど,フロントエンド
    えぬえすとじぇーえす,NestJS
    ぶいゆー,Vue
    りあくと,React
    ねくすとじぇーえす,Next.js
    のーどじぇーえす,Node.js
    とらふぃっく,トラフィック
    あっぷでーと,アップデート
    ぷらいばしー,プライバシー
    すくりーんしょっと,スクリーンショット
    すくしょ,スクショ
    でぃすぷれい,ディスプレイ
    ふぉるだぶる,フォルダブル
    かれんだー,カレンダー
    りまいんだー,リマインダー
    めもちょう,メモ帳
    """
}
