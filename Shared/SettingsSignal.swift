import Foundation

/// アプリ本体で設定を変えたことを、開いているキーボードに知らせる（端末内の通知。中身は運ばず、知らせるだけ）。
/// 知らせを受けたキーボードは、共有の保存先から設定を読み直す。
enum SettingsSignal {
    private static let name = "jp.wataru.duoflick.settings-changed" as CFString
    private static var handler: (() -> Void)?

    static func post() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name), nil, nil, true)
    }

    /// 知らせを受け取る（キーボード側で、1回だけ呼ぶ）
    static func observe(_ block: @escaping () -> Void) {
        handler = block
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async { SettingsSignal.handler?() }
        }, name, nil, .deliverImmediately)
    }
}
