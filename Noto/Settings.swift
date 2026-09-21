import SwiftUI

enum EraserMode: String, CaseIterable, Identifiable {
    case partial // only the touched part of a stroke goes
    case stroke // the whole stroke goes
    case palette // follow the eraser type chosen in the tool palette

    var id: String { rawValue }

    var title: String {
        switch self {
        case .partial: "부분 지우개"
        case .stroke: "획 지우개"
        case .palette: "팔레트 설정 따르기"
        }
    }
}

// User preferences. Read wherever they are used (UserDefaults is cheap), and bound to SettingsView by the same keys.
enum AppSettings {
    enum Key {
        static let shapeSnap = "shapeSnap"
        static let holdDelay = "holdDelay"
        static let pressure = "pressure"
        static let pressureSensitivity = "pressureSensitivity"
        static let eraserMode = "eraserMode"
    }

    static var shapeSnap: Bool { UserDefaults.standard.object(forKey: Key.shapeSnap) as? Bool ?? true }
    static var holdDelay: Double { UserDefaults.standard.object(forKey: Key.holdDelay) as? Double ?? 0.5 }
    static var pressure: Bool { UserDefaults.standard.object(forKey: Key.pressure) as? Bool ?? true }
    static var pressureSensitivity: Double { UserDefaults.standard.object(forKey: Key.pressureSensitivity) as? Double ?? 0.5 }
    static var eraserMode: EraserMode { EraserMode(rawValue: UserDefaults.standard.string(forKey: Key.eraserMode) ?? "") ?? .partial }
}

struct SettingsView: View {
    @AppStorage(AppSettings.Key.pressure) private var pressure = true
    @AppStorage(AppSettings.Key.pressureSensitivity) private var sensitivity = 0.5
    @AppStorage(AppSettings.Key.shapeSnap) private var shapeSnap = true
    @AppStorage(AppSettings.Key.holdDelay) private var holdDelay = 0.5
    @AppStorage(AppSettings.Key.eraserMode) private var eraser = EraserMode.partial.rawValue
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("필압으로 굵기 조절", isOn: $pressure)
                    if pressure {
                        VStack(alignment: .leading) {
                            Text("필압 민감도")
                            Slider(value: $sensitivity, in: 0.1...1)
                        }
                    }
                } header: {
                    Text("펜")
                } footer: {
                    Text("Apple Pencil을 세게 누를수록 선이 굵어집니다. 형광펜에는 적용되지 않습니다.")
                }

                Section {
                    Toggle("펜을 멈추면 직선·원으로 변환", isOn: $shapeSnap)
                    if shapeSnap {
                        Stepper(value: $holdDelay, in: 0.3...1.2, step: 0.1) {
                            Text("멈춤 시간 \(holdDelay, format: .number.precision(.fractionLength(1)))초")
                        }
                    }
                } header: {
                    Text("도형 자동 변환")
                }

                Section {
                    Picker("지우개 방식", selection: $eraser) {
                        ForEach(EraserMode.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("지우개")
                } footer: {
                    Text("부분 지우개는 지우개가 닿은 부분만, 획 지우개는 닿은 획 전체를 지웁니다.")
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
    }
}
