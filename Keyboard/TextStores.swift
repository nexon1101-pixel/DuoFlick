import Foundation
import UIKit

/// クリップボードの履歴。キーボードが開いている間にコピーされたものだけを記録する。
final class ClipboardStore: TextListStore {
    private var lastChangeCount = UIPasteboard.general.changeCount

    init() { super.init(key: "DuoFlick.clipboard.v1", limitFn: { ClipboardLimit.value }) }

    /// コピーされた内容が変わっていれば履歴に足す（フルアクセスが必要）
    /// 文字があるのに中身が読めない（他アプリからの読み取り承認待ち）ときは、
    /// 「確認済み」の印を進めない。進めてしまうと、そのコピーを二度と拾えなくなる
    func capture() {
        let pb = UIPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        guard pb.hasStrings else {
            // 画像だけなど、履歴に残すものが無いコピーは印を進めてよい
            lastChangeCount = pb.changeCount
            return
        }
        guard let s = pb.string else { return }
        lastChangeCount = pb.changeCount
        if !s.isEmpty { add(s) }
    }
}
