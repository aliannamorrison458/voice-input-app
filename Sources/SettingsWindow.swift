import SwiftUI

/// SwiftUI settings window for VoiceInput.
struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    let onSave: (Config) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("VoiceInput 设置")
                    .font(.title2.bold())
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            Form {
                Section("STT 服务") {
                    TextField("服务地址", text: $model.sttUrl)
                        .textFieldStyle(.roundedBorder)
                        .help("STT 服务的 HTTP 地址，例如 http://127.0.0.1:7700")

                    Picker("识别模式", selection: $model.transcribeMode) {
                        Text("文件上传 (file)").tag("file")
                        Text("PCM 流 (pcm)").tag("pcm")
                        Text("WebSocket").tag("websocket")
                    }
                    .help("选择音频传输方式")

                    Picker("后端引擎", selection: $model.backend) {
                        Text("SenseVoice").tag("sensevoice")
                        Text("Whisper").tag("whisper")
                        Text("Paraformer").tag("paraformer")
                    }
                    .help("选择语音识别后端")
                }

                Section("音频") {
                    Picker("语言", selection: $model.language) {
                        Text("自动检测").tag("auto")
                        Text("中文").tag("zh")
                        Text("英文").tag("en")
                        Text("日文").tag("ja")
                        Text("韩文").tag("ko")
                        Text("粤语").tag("yue")
                    }

                    Picker("采样率", selection: $model.sampleRate) {
                        Text("16000 Hz").tag(16000.0)
                        Text("8000 Hz").tag(8000.0)
                        Text("22050 Hz").tag(22050.0)
                        Text("44100 Hz").tag(44100.0)
                    }
                }

                Section("行为") {
                    Toggle("自动粘贴识别结果", isOn: $model.autoPaste)
                    Toggle("录音音效提示", isOn: $model.soundEffect)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            Divider()

            // Buttons
            HStack {
                Button("恢复默认") {
                    model.resetToDefaults()
                }
                .foregroundColor(.secondary)

                Spacer()

                Button("取消") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("保存") {
                    onSave(model.toConfig())
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 460, height: 420)
    }
}

/// Observable model bridging Config ↔ SwiftUI bindings.
final class SettingsModel: ObservableObject {
    @Published var sttUrl: String
    @Published var language: String
    @Published var sampleRate: Double
    @Published var transcribeMode: String
    @Published var backend: String
    @Published var autoPaste: Bool
    @Published var soundEffect: Bool

    init(config: Config) {
        self.sttUrl = config.sttUrl
        self.language = config.language
        self.sampleRate = config.sampleRate
        self.transcribeMode = config.transcribeMode.rawValue
        self.backend = config.backend
        self.autoPaste = config.autoPaste
        self.soundEffect = config.soundEffect
    }

    func toConfig() -> Config {
        Config(
            sttUrl: sttUrl.trimmingCharacters(in: .whitespaces),
            language: language,
            sampleRate: sampleRate,
            transcribeMode: Config.TranscribeMode(rawValue: transcribeMode) ?? .file,
            backend: backend,
            autoPaste: autoPaste,
            soundEffect: soundEffect
        )
    }

    func resetToDefaults() {
        let d = Config.default
        sttUrl = d.sttUrl
        language = d.language
        sampleRate = d.sampleRate
        transcribeMode = d.transcribeMode.rawValue
        backend = d.backend
        autoPaste = d.autoPaste
        soundEffect = d.soundEffect
    }
}

/// NSWindow wrapper for the SwiftUI settings view.
final class SettingsWindowController {
    private var window: NSWindow?
    private var model: SettingsModel
    private let currentConfig: Config
    private let onConfigChanged: (Config) -> Void

    init(config: Config, onConfigChanged: @escaping (Config) -> Void) {
        self.currentConfig = config
        self.model = SettingsModel(config: config)
        self.onConfigChanged = onConfigChanged
    }

    func showWindow() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(
            model: model,
            onSave: { [weak self] newConfig in
                self?.onConfigChanged(newConfig)
                self?.window?.close()
            },
            onCancel: { [weak self] in
                self?.window?.close()
            }
        )

        let hostingView = NSHostingView(rootView: settingsView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoiceInput 设置"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}
