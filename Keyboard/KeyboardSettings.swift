import Foundation
import Combine
import CoreGraphics

enum KeyboardShape: String, Codable, CaseIterable {
    case standard   // 画面いっぱいの格子（両手、iPhone標準に近い）
    case rightGrid  // 片手用の格子（右手なら右寄せ、左手なら左寄せ）
    case fan        // 片手用の扇形
}

/// 持ち方。片手持ち用と両手持ち用で、別々の設定を覚える
enum Grip: String, Codable {
    case one, two

    var title: String { self == .one ? "片手持ち" : "両手持ち" }
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
    /// キーの文字の大きさ（倍率）
    var labelScale: Double = 1.0
    /// 配色（ライトモード・ダークモード別）
    var themeLight: String = "standard"
    var themeDark: String = "standard"
    /// キーを押したときの振動（フルアクセスが必要）
    var haptics: Bool = true
    /// 押した位置のずれを覚えて判定を補正する
    var autoCorrect: Bool = true
    /// 同じキーを続けてタップすると文字が切り替わる（あ→い→う…、iOS標準のトグル入力）。初期はオフ
    var toggleTap: Bool = false
    /// 打ち間違いを直した候補も出す（変換エンジンの機能）。初期はオフ
    var typoCorrection: Bool = false

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
        labelScale = (try? c.decode(Double.self, forKey: .labelScale)) ?? d.labelScale
        themeLight = (try? c.decode(String.self, forKey: .themeLight)) ?? d.themeLight
        themeDark = (try? c.decode(String.self, forKey: .themeDark)) ?? d.themeDark
        haptics = (try? c.decode(Bool.self, forKey: .haptics)) ?? d.haptics
        autoCorrect = (try? c.decode(Bool.self, forKey: .autoCorrect)) ?? d.autoCorrect
        toggleTap = (try? c.decode(Bool.self, forKey: .toggleTap)) ?? d.toggleTap
        typoCorrection = (try? c.decode(Bool.self, forKey: .typoCorrection)) ?? d.typoCorrection
    }

    /// iPhoneの1ポイントはおよそ0.16mm。機種ごとの差は小さいので固定値で扱う。
    static let ptPerMM: Double = 6.1
    static func load(profile: ScreenProfile, grip: Grip) -> KeyboardSettings {
        if let s = stored(profile.storeKey(grip)) { return s }
        // まだなければ、もう一方の持ち方の設定を元に、形だけ変えて作る
        let other: Grip = grip == .one ? .two : .one
        var base = stored(profile.storeKey(other))
            ?? (profile == .wide ? stored(ScreenProfile.narrow.storeKey(.one)) : nil)
            ?? KeyboardSettings()
        if grip == .two {
            if base.shape != .standard { base.oneHandShape = base.shape }
            base.shape = .standard
        } else if base.shape == .standard {
            base.shape = base.oneHandShape == .standard ? .rightGrid : base.oneHandShape
        }
        return base
    }

    private static func stored(_ key: String) -> KeyboardSettings? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KeyboardSettings.self, from: data)
    }

    func save(profile: ScreenProfile, grip: Grip) {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: profile.storeKey(grip))
        }
    }
}

/// 画面の幅で設定を分ける（iPhone Duo の外側画面と、開いた内側画面）
enum ScreenProfile: String {
    case narrow, wide

    static func forWidth(_ w: CGFloat) -> ScreenProfile { w > 480 ? .wide : .narrow }

    /// これまでの設定（外側画面は片手持ち、内側画面は両手持ち）はそのままの場所に残す
    func storeKey(_ grip: Grip) -> String {
        switch (self, grip) {
        case (.narrow, .one): return "DuoFlick.settings.v1"
        case (.narrow, .two): return "DuoFlick.settings.narrow2.v1"
        case (.wide, .one): return "DuoFlick.settings.wide1.v1"
        case (.wide, .two): return "DuoFlick.settings.wide.v1"
        }
    }
    var title: String { self == .narrow ? "外側画面" : "内側画面" }
}

/// 保存した設定（最大5つ）
struct SavedPreset: Codable, Identifiable {
    var id = UUID()
    var name: String
    var settings: KeyboardSettings
}

final class SettingsModel: ObservableObject {
    @Published var settings: KeyboardSettings {
        didSet {
            if settings != oldValue {
                settings.save(profile: profile, grip: grip)
                onChange?(settings)
            }
        }
    }
    @Published private(set) var profile: ScreenProfile = .narrow
    @Published private(set) var grip: Grip
    private static let gripKey = "DuoFlick.grip.v1"

    /// 設定画面に出す名前（例：外側画面・片手持ち）
    var title: String { "\(profile.title)・\(grip.title)" }
    @Published private(set) var presets: [SavedPreset] = []
    var onChange: ((KeyboardSettings) -> Void)?

    private static let presetKey = "DuoFlick.presets.v1"

    init() {
        let g = Grip(rawValue: UserDefaults.standard.string(forKey: Self.gripKey) ?? "") ?? .one
        grip = g
        settings = KeyboardSettings.load(profile: .narrow, grip: g)
        if let data = UserDefaults.standard.data(forKey: Self.presetKey),
           let list = try? JSONDecoder().decode([SavedPreset].self, from: data) {
            presets = list
        }
    }

    /// 画面の幅が変わったら、その画面用の設定に切り替える
    func use(profile p: ScreenProfile) {
        guard p != profile else { return }
        profile = p
        settings = KeyboardSettings.load(profile: p, grip: grip)
        onChange?(settings)
    }

    /// 片手持ち⇄両手持ちを切り替える
    func toggleGrip() {
        grip = grip == .one ? .two : .one
        UserDefaults.standard.set(grip.rawValue, forKey: Self.gripKey)
        let s = KeyboardSettings.load(profile: profile, grip: grip)
        if s == settings {
            onChange?(settings)
        } else {
            settings = s
        }
        settings.save(profile: profile, grip: grip)
    }

    func savePreset() {
        let n = (1...9).first { i in !presets.contains { $0.name == "設定\(i)" } } ?? presets.count + 1
        presets.insert(SavedPreset(name: "設定\(n)", settings: settings), at: 0)
        if presets.count > 5 { presets.removeLast(presets.count - 5) }
        storePresets()
    }

    func loadPreset(_ p: SavedPreset) {
        settings = p.settings
    }

    func deletePreset(_ p: SavedPreset) {
        presets.removeAll { $0.id == p.id }
        storePresets()
    }

    private func storePresets() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: Self.presetKey)
        }
    }
}
