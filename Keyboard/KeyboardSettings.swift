import Foundation
import Combine

enum KeyboardShape: String, Codable, CaseIterable {
    case standard   // 画面いっぱいの格子（両手、iPhone標準に近い）
    case rightGrid  // 片手用の格子（右手なら右寄せ、左手なら左寄せ）
    case fan        // 片手用の扇形
}

/// 片手で使うときの手
enum Hand: String, Codable {
    case right, left
}

/// キーボードの形と大きさ。キーボード拡張の中だけで保存する（無料アカウントでは App Groups が使えないため）。
struct KeyboardSettings: Codable, Equatable {
    var shape: KeyboardShape = .standard
    var keyWidthMM: Double = 9.5
    var keyHeightMM: Double = 9.6
    var gapMM: Double = 1.0
    var edgeGrowPercent: Double = 0
    var marginMM: Double = 1.0
    var bottomMarginMM: Double = 3.0
    var fanRadiusMM: Double = 80
    var fanAngleDeg: Double = 97
    var flickMinMM: Double = 3.5
    var tiltDeg: Double = 0
    /// 扇形のとき、文字・フリックガイド・フリック方向をキーの傾きに合わせる
    var followFan: Bool = true
    var hand: Hand = .right
    /// 両手から片手に戻すときに使う形
    var oneHandShape: KeyboardShape = .rightGrid

    init(shape: KeyboardShape = .standard) {
        self.shape = shape
    }

    // 古い設定データに項目が足りなくても読めるようにする
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = KeyboardSettings()
        shape = (try? c.decode(KeyboardShape.self, forKey: .shape)) ?? d.shape
        keyWidthMM = (try? c.decode(Double.self, forKey: .keyWidthMM)) ?? d.keyWidthMM
        keyHeightMM = (try? c.decode(Double.self, forKey: .keyHeightMM)) ?? d.keyHeightMM
        gapMM = (try? c.decode(Double.self, forKey: .gapMM)) ?? d.gapMM
        edgeGrowPercent = (try? c.decode(Double.self, forKey: .edgeGrowPercent)) ?? d.edgeGrowPercent
        marginMM = (try? c.decode(Double.self, forKey: .marginMM)) ?? d.marginMM
        bottomMarginMM = (try? c.decode(Double.self, forKey: .bottomMarginMM)) ?? d.bottomMarginMM
        fanRadiusMM = (try? c.decode(Double.self, forKey: .fanRadiusMM)) ?? d.fanRadiusMM
        fanAngleDeg = (try? c.decode(Double.self, forKey: .fanAngleDeg)) ?? d.fanAngleDeg
        flickMinMM = (try? c.decode(Double.self, forKey: .flickMinMM)) ?? d.flickMinMM
        tiltDeg = (try? c.decode(Double.self, forKey: .tiltDeg)) ?? d.tiltDeg
        followFan = (try? c.decode(Bool.self, forKey: .followFan)) ?? d.followFan
        hand = (try? c.decode(Hand.self, forKey: .hand)) ?? d.hand
        oneHandShape = (try? c.decode(KeyboardShape.self, forKey: .oneHandShape)) ?? d.oneHandShape
    }

    /// iPhoneの1ポイントはおよそ0.16mm。機種ごとの差は小さいので固定値で扱う。
    static let ptPerMM: Double = 6.1
    private static let storeKey = "DuoFlick.settings.v1"

    static func load() -> KeyboardSettings {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let s = try? JSONDecoder().decode(KeyboardSettings.self, from: data) else {
            return KeyboardSettings()
        }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }
}

final class SettingsModel: ObservableObject {
    @Published var settings: KeyboardSettings {
        didSet { if settings != oldValue { onChange?(settings) } }
    }
    var onChange: ((KeyboardSettings) -> Void)?

    init() {
        settings = KeyboardSettings.load()
    }
}
