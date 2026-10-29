import SwiftUI

struct TuningParam: Identifiable {
    let id: String
    let label: String
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let keyPath: WritableKeyPath<KeyboardSettings, Double>
    let shapes: [KeyboardShape]
}

enum TuningParams {
    static let all: [TuningParam] = [
        TuningParam(id: "w", label: "キーの幅", range: 6...16, step: 0.1, unit: "mm",
                    keyPath: \.keyWidthMM, shapes: [.rightGrid, .fan]),
        TuningParam(id: "h", label: "キーの高さ", range: 6...16, step: 0.1, unit: "mm",
                    keyPath: \.keyHeightMM, shapes: KeyboardShape.allCases),
        TuningParam(id: "g", label: "キーの間隔", range: 0...3, step: 0.1, unit: "mm",
                    keyPath: \.gapMM, shapes: KeyboardShape.allCases),
        TuningParam(id: "e", label: "遠いキーの拡大", range: 0...50, step: 1, unit: "%",
                    keyPath: \.edgeGrowPercent, shapes: [.rightGrid, .fan]),
        TuningParam(id: "m", label: "端の余白", range: 0...20, step: 0.5, unit: "mm",
                    keyPath: \.marginMM, shapes: KeyboardShape.allCases),
        TuningParam(id: "b", label: "下の余白", range: 0...20, step: 0.5, unit: "mm",
                    keyPath: \.bottomMarginMM, shapes: KeyboardShape.allCases),
        TuningParam(id: "r", label: "カーブの半径", range: 25...200, step: 1, unit: "mm",
                    keyPath: \.fanRadiusMM, shapes: [.fan]),
        TuningParam(id: "a", label: "扇の向き", range: 60...150, step: 1, unit: "°",
                    keyPath: \.fanAngleDeg, shapes: [.fan]),
        TuningParam(id: "f", label: "フリック距離", range: 1.5...8, step: 0.1, unit: "mm",
                    keyPath: \.flickMinMM, shapes: KeyboardShape.allCases),
        TuningParam(id: "t", label: "方向の傾き", range: -30...30, step: 1, unit: "°",
                    keyPath: \.tiltDeg, shapes: KeyboardShape.allCases),
    ]
}

/// キーボードの上に出す調整バー。数値を変えるとすぐ下のキーボードに反映される。
struct TuningBar: View {
    @ObservedObject var model: SettingsModel
    let onClose: () -> Void
    @State private var selectedID = "w"

    private var params: [TuningParam] {
        TuningParams.all.filter { $0.shapes.contains(model.settings.shape) }
    }
    private var current: TuningParam? {
        params.first { $0.id == selectedID } ?? params.first
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Picker("形", selection: $model.settings.shape) {
                    Text("標準").tag(KeyboardShape.standard)
                    Text("右寄せ").tag(KeyboardShape.rightGrid)
                    Text("扇形").tag(KeyboardShape.fan)
                }
                .pickerStyle(.segmented)
                Button("閉じる", action: onClose)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(params) { p in
                        let on = p.id == current?.id
                        Button(p.label) { selectedID = p.id }
                            .font(.footnote)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(on ? Color.accentColor : Color(uiColor: .secondarySystemBackground)))
                            .foregroundStyle(on ? Color.white : Color.primary)
                    }
                    Button("初期値に戻す") {
                        model.settings = KeyboardSettings(shape: model.settings.shape)
                    }
                    .font(.footnote)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                }
            }
            if let p = current {
                HStack(spacing: 8) {
                    Button { nudge(p, -p.step) } label: {
                        Image(systemName: "minus.circle.fill").font(.title3)
                    }
                    Slider(value: binding(p), in: p.range, step: p.step)
                    Button { nudge(p, p.step) } label: {
                        Image(systemName: "plus.circle.fill").font(.title3)
                    }
                    Text(format(p))
                        .font(.footnote.monospacedDigit())
                        .frame(width: 60, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func binding(_ p: TuningParam) -> Binding<Double> {
        Binding(
            get: { model.settings[keyPath: p.keyPath] },
            set: { model.settings[keyPath: p.keyPath] = $0 }
        )
    }

    private func nudge(_ p: TuningParam, _ delta: Double) {
        let v = model.settings[keyPath: p.keyPath] + delta
        let clamped = min(p.range.upperBound, max(p.range.lowerBound, v))
        model.settings[keyPath: p.keyPath] = (clamped / p.step).rounded() * p.step
    }

    private func format(_ p: TuningParam) -> String {
        let v = model.settings[keyPath: p.keyPath]
        let number = p.step < 1 ? String(format: "%.1f", v) : String(format: "%.0f", v)
        return number + p.unit
    }
}
