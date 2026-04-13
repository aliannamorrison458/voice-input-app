import AppKit
import AVFoundation
import CoreAudio

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var recorder: AudioRecorder!
    private var sttClient: STTClient!
    private var hotkeyMonitor: HotkeyMonitor!
    private var config: Config!
    private var isRecording = false
    private var isProcessing = false
    private var lastText = ""
    private var statusMenuItem: NSMenuItem!
    private var recordMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = Config.load()
        recorder = AudioRecorder(sampleRate: config.sampleRate)
        sttClient = STTClient(baseURL: config.sttUrl, language: config.language)

        setupMenu()
        setupHotkey()
        checkSTTService()
    }

    // MARK: - Menu Bar

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎤"

        let menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "检查服务中...", action: nil, keyEquivalent: "")
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        recordMenuItem = NSMenuItem(title: "🎙️ 开始录音 (Fn)", action: #selector(toggleRecord), keyEquivalent: "")
        recordMenuItem.target = self
        menu.addItem(recordMenuItem)

        let pasteItem = NSMenuItem(title: "📋 粘贴上次结果", action: #selector(pasteLast), keyEquivalent: "")
        pasteItem.target = self
        menu.addItem(pasteItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "⚙️ 设置...", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let logItem = NSMenuItem(title: "📝 查看日志", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "❌ 退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Hotkey

    private func setupHotkey() {
        hotkeyMonitor = HotkeyMonitor { [weak self] pressed in
            guard let self else { return }
            if pressed {
                self.onHotkeyPress()
            } else {
                self.onHotkeyRelease()
            }
        }
        hotkeyMonitor.start()
    }

    private func onHotkeyPress() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isRecording, !self.isProcessing else { return }
            self.startRecording()
        }
    }

    private func onHotkeyRelease() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording else { return }
            self.stopRecordingAndTranscribe()
        }
    }

    // MARK: - Service Check

    private func checkSTTService() {
        Task {
            let ok = await sttClient.healthCheck()
            await MainActor.run {
                statusMenuItem.title = ok ? "✅ STT 服务在线" : "❌ STT 服务离线"
            }
        }
    }

    // MARK: - Recording

    private func startRecording() {
        isRecording = true
        statusItem.button?.title = "🔴"
        recordMenuItem.title = "⏹️ 停止录音"

        do {
            try recorder.start()
            if config.soundEffect { SoundEffect.play(.start) }
        } catch {
            isRecording = false
            statusItem.button?.title = "🎤"
            recordMenuItem.title = "🎙️ 开始录音 (Fn)"
            showError("录音启动失败: \(error.localizedDescription)")
        }
    }

    private func stopRecordingAndTranscribe() {
        guard let audioData = recorder.stop() else {
            isRecording = false
            statusItem.button?.title = "🎤"
            recordMenuItem.title = "🎙️ 开始录音 (Fn)"
            return
        }

        isRecording = false
        isProcessing = true
        statusItem.button?.title = "⏳"
        recordMenuItem.title = "⏳ 识别中..."
        if config.soundEffect { SoundEffect.play(.stop) }

        Task {
            do {
                let text = try await sttClient.transcribe(audioData: audioData)
                await MainActor.run {
                    if !text.isEmpty {
                        self.lastText = text
                        if self.config.autoPaste {
                            TextInjector.inject(text)
                        }
                        self.showNotification("✅ 识别完成", body: String(text.prefix(50)))
                    }
                    self.resetUI()
                }
            } catch {
                await MainActor.run {
                    self.showError("识别失败: \(error.localizedDescription)")
                    self.resetUI()
                }
            }
        }
    }

    private func resetUI() {
        isRecording = false
        isProcessing = false
        statusItem.button?.title = "🎤"
        recordMenuItem.title = "🎙️ 开始录音 (Fn)"
    }

    // MARK: - Menu Actions

    @objc private func toggleRecord() {
        if isRecording {
            stopRecordingAndTranscribe()
        } else if !isProcessing {
            startRecording()
        }
    }

    @objc private func pasteLast() {
        if !lastText.isEmpty {
            TextInjector.inject(lastText)
        }
    }

    @objc private func openSettings() {
        NSWorkspace.shared.open(Config.configFileURL)
    }

    @objc private func openLog() {
        let logURL = Config.configDirURL.appendingPathComponent("log.txt")
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.open(logURL)
        }
    }

    @objc private func quitApp() {
        hotkeyMonitor.stop()
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func showError(_ message: String) {
        showNotification("错误", body: message)
    }

    private func showNotification(_ title: String, body: String) {
        let notification = NSUserNotification()
        notification.title = "Voice Input"
        notification.subtitle = title
        notification.informativeText = body
        notification.soundName = nil
        NSUserNotificationCenter.default.deliver(notification)
    }
}
