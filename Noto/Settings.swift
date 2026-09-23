import SwiftUI

enum EraserMode: String, CaseIterable, Identifiable {
    case partial // only the touched part of a stroke goes
    case stroke // the whole stroke goes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .partial: "부분 지우개"
        case .stroke: "획 지우개"
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
        static let eraserSize = "eraserSize"
        static let highlighterTextSnap = "highlighterTextSnap"
        static let audioSyncAutoScroll = "audioSyncAutoScroll"
        static let audioSyncHighlight = "audioSyncHighlight"
    }

    static var shapeSnap: Bool { UserDefaults.standard.object(forKey: Key.shapeSnap) as? Bool ?? true }
    static var holdDelay: Double { UserDefaults.standard.object(forKey: Key.holdDelay) as? Double ?? 0.5 }
    static var pressure: Bool { UserDefaults.standard.object(forKey: Key.pressure) as? Bool ?? true }
    static var pressureSensitivity: Double { UserDefaults.standard.object(forKey: Key.pressureSensitivity) as? Double ?? 0.6 }
    static var eraserMode: EraserMode { EraserMode(rawValue: UserDefaults.standard.string(forKey: Key.eraserMode) ?? "") ?? .partial }
    static var eraserSize: Double { UserDefaults.standard.object(forKey: Key.eraserSize) as? Double ?? 12 } // radius in screen points
    static var highlighterTextSnap: Bool { UserDefaults.standard.object(forKey: Key.highlighterTextSnap) as? Bool ?? true }
    static var audioSyncAutoScroll: Bool { UserDefaults.standard.object(forKey: Key.audioSyncAutoScroll) as? Bool ?? true }
    static var audioSyncHighlight: Bool { UserDefaults.standard.object(forKey: Key.audioSyncHighlight) as? Bool ?? true }
}

struct SettingsView: View {
    @AppStorage(AppSettings.Key.pressure) private var pressure = true
    @AppStorage(AppSettings.Key.pressureSensitivity) private var sensitivity = 0.6
    @AppStorage(AppSettings.Key.eraserSize) private var eraserSize = 12.0
    @AppStorage(AppSettings.Key.shapeSnap) private var shapeSnap = true
    @AppStorage(AppSettings.Key.holdDelay) private var holdDelay = 0.5
    @AppStorage(AppSettings.Key.eraserMode) private var eraser = EraserMode.partial.rawValue
    @AppStorage(AppSettings.Key.highlighterTextSnap) private var highlighterTextSnap = true
    @AppStorage(AppSettings.Key.audioSyncAutoScroll) private var audioSyncAutoScroll = true
    @AppStorage(AppSettings.Key.audioSyncHighlight) private var audioSyncHighlight = true
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
                    Toggle("텍스트에 맞춰 자동 정렬", isOn: $highlighterTextSnap)
                } header: {
                    Text("형광펜")
                } footer: {
                    Text("텍스트가 있는 PDF(스캔본은 OCR이 된 경우)에서 줄 위를 대충 그어도 그 줄 전체에 깔끔하게 맞춰 그어집니다. 텍스트가 없는 페이지에서는 손으로 그린 그대로 그어집니다.")
                }

                Section {
                    Toggle("재생 중 페이지 자동 이동", isOn: $audioSyncAutoScroll)
                    Toggle("재생 중 필기 하이라이트", isOn: $audioSyncHighlight)
                } header: {
                    Text("녹음 재생")
                } footer: {
                    Text("녹음을 재생하면 그 시점에 쓰던 필기를 표시합니다. 다른 페이지에 있을 때 자동으로 이동할지, 필기를 강조 표시할지 각각 켜고 끌 수 있습니다.")
                }

                Section {
                    Picker("지우개 방식", selection: $eraser) {
                        ForEach(EraserMode.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    VStack(alignment: .leading) {
                        Text("지우개 크기 \(Int(eraserSize))")
                        Slider(value: $eraserSize, in: 4...40, step: 1)
                    }
                } header: {
                    Text("지우개")
                } footer: {
                    Text("부분 지우개는 지우개가 닿은 부분만, 획 지우개는 닿은 획 전체를 지웁니다. 지우개를 대고 있는 동안 범위가 원으로 표시됩니다.")
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
