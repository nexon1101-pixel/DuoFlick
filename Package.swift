// swift-tools-version: 5.9
import PackageDescription

// キーボード本体（Keyboard/ と Shared/）をライブラリとして切り出したパッケージ。
// DuoFlick 単体のアプリと、採用箱（DuoRemote 側のアプリ）の両方が、
// それぞれのキーボード拡張ターゲットからこのパッケージを取り込んで使う。
// SkkDict はパッケージに含めず、各アプリの拡張ターゲットがフォルダ参照で同梱する
// （本体コードは Bundle.main から探すため）。
let package = Package(
    name: "DuoFlickKeyboardCore",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "DuoFlickKeyboardCore", targets: ["DuoFlickKeyboardCore"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter",
            revision: "3f93209534c148a563d92ef77059953b51777266"
        )
    ],
    targets: [
        .target(
            name: "DuoFlickKeyboardCore",
            dependencies: [
                .product(
                    name: "KanaKanjiConverterModuleWithDefaultDictionary",
                    package: "AzooKeyKanaKanjiConverter"
                )
            ],
            path: ".",
            exclude: ["Keyboard/Info.plist", "Keyboard/SkkDict"],
            sources: ["Keyboard", "Shared"]
        )
    ]
)
