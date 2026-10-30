import Foundation

struct TuningParam: Identifiable {
    let id: String
    let label: String
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let keyPath: WritableKeyPath<KeyboardSettings, Double>
    let shapes: [KeyboardShape]
    /// 比べて決めるときの、最初のAとBの差の半分
    let compareDelta: Double?
}

enum TuningParams {
    static let all: [TuningParam] = [
        TuningParam(id: "w", label: "キーの幅", range: 6...16, step: 0.1, unit: "mm",
                    keyPath: \.keyWidthMM, shapes: [.rightGrid, .fan], compareDelta: 1.5),
        TuningParam(id: "h", label: "キーの高さ", range: 6...16, step: 0.1, unit: "mm",
                    keyPath: \.keyHeightMM, shapes: KeyboardShape.allCases, compareDelta: 1.5),
        TuningParam(id: "r", label: "カーブの半径", range: 25...200, step: 1, unit: "mm",
                    keyPath: \.fanRadiusMM, shapes: [.fan], compareDelta: 30),
        TuningParam(id: "a", label: "扇の向き", range: 60...150, step: 1, unit: "°",
                    keyPath: \.fanAngleDeg, shapes: [.fan], compareDelta: 10),
        TuningParam(id: "m", label: "端の余白", range: 0...20, step: 0.5, unit: "mm",
                    keyPath: \.marginMM, shapes: KeyboardShape.allCases, compareDelta: 3),
        TuningParam(id: "s", label: "真ん中の空き", range: 5...40, step: 1, unit: "%",
                    keyPath: \.splitGapPercent, shapes: [.standard], compareDelta: nil),
        TuningParam(id: "b", label: "下の余白", range: 0...20, step: 0.5, unit: "mm",
                    keyPath: \.bottomMarginMM, shapes: KeyboardShape.allCases, compareDelta: 3),
        TuningParam(id: "f", label: "フリック距離", range: 1.5...8, step: 0.1, unit: "mm",
                    keyPath: \.flickMinMM, shapes: KeyboardShape.allCases, compareDelta: 1.5),
        TuningParam(id: "g", label: "キーの間隔", range: 0...3, step: 0.1, unit: "mm",
                    keyPath: \.gapMM, shapes: KeyboardShape.allCases, compareDelta: nil),
        TuningParam(id: "e", label: "遠いキーの拡大", range: 0...50, step: 1, unit: "%",
                    keyPath: \.edgeGrowPercent, shapes: [.rightGrid, .fan], compareDelta: nil),
        TuningParam(id: "t", label: "方向の傾き", range: -30...30, step: 1, unit: "°",
                    keyPath: \.tiltDeg, shapes: KeyboardShape.allCases, compareDelta: nil),
        TuningParam(id: "c", label: "カーソル移動の速さ", range: 0.5...2.5, step: 0.1, unit: "倍",
                    keyPath: \.cursorSpeed, shapes: KeyboardShape.allCases, compareDelta: nil),
        TuningParam(id: "l", label: "文字の大きさ", range: 0.7...1.4, step: 0.05, unit: "倍",
                    keyPath: \.labelScale, shapes: KeyboardShape.allCases, compareDelta: nil),
    ]

    static func clamp(_ p: TuningParam, _ v: Double) -> Double {
        let c = min(p.range.upperBound, max(p.range.lowerBound, v))
        return (c / p.step).rounded() * p.step
    }

    static func format(_ p: TuningParam, _ v: Double) -> String {
        let number = p.step < 0.1 ? String(format: "%.2f", v) : (p.step < 1 ? String(format: "%.1f", v) : String(format: "%.0f", v))
        return number + p.unit
    }
}
