import Foundation
import Combine

enum KeyboardShape: String, Codable, CaseIterable {
    case standard   // 画面いっぱいの格子（iPhone標準に近い）
    case rightGrid  // 右寄せの格子（右手の親指用）
    case fan        // 扇形（右手の親指用）
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
