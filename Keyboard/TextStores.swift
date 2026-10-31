import Foundation
import UIKit

/// クリップボードの履歴。キーボードが開いている間にコピーされたものだけを記録する。
final class ClipboardStore: TextListStore {
    private var lastChangeCount = UIPasteboard.general.changeCount

    init() { super.init(key: "DuoFlick.clipboard.v1", limitFn: { ClipboardLimit.value }) }

    /// コピーされた内容が変わっていれば履歴に足す（フルアクセスが必要）
    func capture() {
        let pb = UIPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard pb.hasStrings, let s = pb.string else { return }
        add(s)
    }
}
