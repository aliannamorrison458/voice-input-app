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
        AppLogger.info("应用启动, STT=\(config.sttUrl), language=\(config.language), sampleRate=\(Int(config.sampleRate))")

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
            let result = await sttClient.healthCheck()
            await MainActor.run {
                statusMenuItem.title = result.isOnline ? "✅ STT 服务在线" : "❌ STT 服务离线"
            }
            if result.isOnline {
                AppLogger.info("服务健康检查: online (\(result.reason))")
            } else {
                AppLogger.warn("服务健康检查: offline, 原因: \(result.reason)")
            }
        }
    }

    // MARK: - Recording

    private func startRecording() {
        isRecording = true
        statusItem.button?.title = "🔴"
        recordMenuItem.title = "⏹️ 停止录音"
        AppLogger.info("开始录音")

        do {
            try recorder.start()
            if config.soundEffect { SoundEffect.play(.start) }
        } catch {
            isRecording = false
            statusItem.button?.title = "🎤"
            recordMenuItem.title = "🎙️ 开始录音 (Fn)"
            AppLogger.error("录音启动失败: \(error.localizedDescription)")
            showError("录音启动失败: \(error.localizedDescription)")
        }
    }

    private func stopRecordingAndTranscribe() {
        guard let audioData = recorder.stop() else {
            isRecording = false
            statusItem.button?.title = "🎤"
            recordMenuItem.title = "🎙️ 开始录音 (Fn)"
            AppLogger.warn("停止录音后没有采集到音频数据")
            return
        }
        AppLogger.info("停止录音, 采集字节数=\(audioData.count)")

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
                            AppLogger.info("识别成功并自动粘贴, 文本长度=\(text.count)")
                        } else {
                            AppLogger.info("识别成功, 文本长度=\(text.count)")
                        }
                        self.showNotification("✅ 识别完成", body: String(text.prefix(50)))
                    } else {
                        AppLogger.warn("识别成功但返回空文本")
                    }
                    self.resetUI()
                }
            } catch {
                await MainActor.run {
                    AppLogger.error("识别失败: \(error.localizedDescription)")
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
        AppLogger.info("打开配置文件")
        NSWorkspace.shared.open(Config.configFileURL)
    }

    @objc private func openLog() {
        let logURL = Config.configDirURL.appendingPathComponent("log.txt")
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(at: Config.configDirURL, withIntermediateDirectories: true)

            if !fileManager.fileExists(atPath: logURL.path) {
                fileManager.createFile(atPath: logURL.path, contents: Data(), attributes: nil)
            }

            if !NSWorkspace.shared.open(logURL) {
                AppLogger.error("无法打开日志文件: \(logURL.path)")
                showError("无法打开日志文件: \(logURL.path)")
            } else {
                AppLogger.info("打开日志文件")
            }
        } catch {
            AppLogger.error("准备日志文件失败: \(error.localizedDescription)")
            showError("准备日志文件失败: \(error.localizedDescription)")
        }
    }

    @objc private func quitApp() {
        AppLogger.info("应用退出")
        hotkeyMonitor.stop()
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func showError(_ message: String) {
        AppLogger.error(message)
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
