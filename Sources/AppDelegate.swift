import AppKit
import AVFoundation
import CoreAudio
import UserNotifications
import ServiceManagement
import QuartzCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var recorder: AudioRecorder!
    private var sttClient: STTClient?
    private var hotkeyMonitor: HotkeyMonitor!
    private var config: Config!
    private var isRecording = false
    private var isProcessing = false
    private var lastText = ""
    private var statusMenuItem: NSMenuItem!
    private var recordMenuItem: NSMenuItem!
    private var lastResultMenuItem: NSMenuItem!
    private var recordStartTime: Date?
    private var durationTimer: Timer?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permission
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        config = Config.load()
        recorder = AudioRecorder(sampleRate: config.sampleRate)
        sttClient = STTClient(
            baseURL: config.sttUrl,
            language: config.language,
            sampleRate: config.sampleRate,
            transcribeMode: config.transcribeMode,
            backend: config.backend
        )
        if sttClient == nil {
            AppLogger.error("STT 客户端初始化失败，URL 无效: \(config.sttUrl)")
        }
        AppLogger.info("应用启动, STT=\(config.sttUrl), language=\(config.language), sampleRate=\(Int(config.sampleRate)), mode=\(config.transcribeMode.rawValue), backend=\(config.backend)")

        setupMenu()
        setupHotkey()
        checkSTTService()
        checkAccessibilityPermission()
        checkDiskSpace()

        settingsWindowController = SettingsWindowController(config: config) { [weak self] newConfig in
            self?.applyConfig(newConfig)
        }

        // Periodic health checks: disk + accessibility every 60s
        startPeriodicHealthChecks()

        // First-launch onboarding
        showOnboardingIfNeeded()
    }

    private func showOnboardingIfNeeded() {
        let key = "VoiceInput.hasShownOnboarding"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.showNotification(
                    "👋 欢迎使用 VoiceInput",
                    body: "按住 Fn 键开始说话，松开自动识别。点击菜单栏 🎤 图标查看更多功能。"
                )
            }
        }
    }

    private var healthCheckTimer: Timer?

    private func startPeriodicHealthChecks() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkDiskSpace()
            self?.recheckAccessibilityPermission()
        }
    }

    private func checkDiskSpace() {
        let configDir = Config.configDirURL
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: configDir.path)
            if let freeSpace = attrs[.systemFreeSize] as? UInt64 {
                let freeMB = Double(freeSpace) / (1024 * 1024)
                if freeMB < 100 {
                    AppLogger.warn("磁盘空间不足: 剩余 \(Int(freeMB))MB")
                    showError("磁盘空间不足（剩余 \(Int(freeMB))MB），日志可能无法正常写入")
                }
            }
        } catch {
            // Silently ignore - non-critical check
        }
    }

    private var accessibilityWasGranted = AXIsProcessTrusted()

    private func recheckAccessibilityPermission() {
        let currentlyGranted = AXIsProcessTrusted()
        if accessibilityWasGranted && !currentlyGranted {
            AppLogger.warn("辅助功能权限已被撤回")
            showError("辅助功能权限已失效，文字注入将无法工作。请在系统设置中重新启用。")
        }
        accessibilityWasGranted = currentlyGranted
    }

    // MARK: - Menu Bar

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusBarIcon(.idle)

        let menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "检查服务中...", action: nil, keyEquivalent: "")
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        recordMenuItem = NSMenuItem(title: "🎙️ 开始录音 (Fn)", action: #selector(toggleRecord), keyEquivalent: "")
        recordMenuItem.target = self
        menu.addItem(recordMenuItem)

        lastResultMenuItem = NSMenuItem(title: "📋 粘贴上次结果", action: #selector(pasteLast), keyEquivalent: "")
        lastResultMenuItem.target = self
        lastResultMenuItem.isEnabled = false
        menu.addItem(lastResultMenuItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "⚙️ 设置...", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let logItem = NSMenuItem(title: "📝 查看日志", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        let launchItem = NSMenuItem(title: "🚀 开机自启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchItem)

        // Help section
        let helpItem = NSMenuItem(title: "❓ 使用帮助", action: #selector(showHelp), keyEquivalent: "?")
        helpItem.target = self
        menu.addItem(helpItem)

        // Version info
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let versionString = build.isEmpty ? version : "\(version) (\(build))"
        let versionItem = NSMenuItem(title: "ℹ️ VoiceInput v\(versionString)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "❌ 退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private enum StatusBarState {
        case idle, recording, processing, error
    }

    // Pulse animation for recording state
    private var pulseTimer: Timer?
    private var pulseState = false

    private func updateStatusBarIcon(_ state: StatusBarState) {
        // Stop any running animation
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulseState = false

        switch state {
        case .idle:
            statusItem.button?.title = "🎤"
            statusItem.button?.toolTip = "VoiceInput 就绪\n按住 Fn 键开始录音\n点击菜单查看更多选项"
            statusItem.button?.alphaValue = 1.0
        case .recording:
            statusItem.button?.title = "🔴"
            statusItem.button?.toolTip = "正在录音中…\n松开 Fn 键停止并识别"
            statusItem.button?.alphaValue = 1.0
            // Start pulse animation
            startPulseAnimation()
        case .processing:
            statusItem.button?.title = "⏳"
            statusItem.button?.toolTip = "正在识别中…\n请稍候"
            statusItem.button?.alphaValue = 1.0
        case .error:
            statusItem.button?.title = "⚠️"
            statusItem.button?.toolTip = "出现问题\n点击菜单查看详情或重试"
            statusItem.button?.alphaValue = 1.0
        }
    }

    private func startPulseAnimation() {
        pulseTimer?.invalidate()
        pulseState = true
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.isRecording else {
                self?.pulseTimer?.invalidate()
                self?.pulseTimer = nil
                self?.statusItem.button?.alphaValue = 1.0
                return
            }
            self.pulseState.toggle()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.statusItem.button?.animator().alphaValue = self.pulseState ? 1.0 : 0.3
            }
        }
    }

    // MARK: - Accessibility Check

    private func checkAccessibilityPermission() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if !AXIsProcessTrusted() {
                AppLogger.warn("辅助功能权限未授权")
                let alert = NSAlert()
                alert.messageText = "需要辅助功能权限"
                alert.informativeText = "VoiceInput 需要辅助功能权限才能将识别的文字输入到其他应用。\n\n请在「系统设置 → 隐私与安全 → 辅助功能」中启用 VoiceInput。"
                alert.alertStyle = .informational
                alert.addButton(withTitle: "打开系统设置")
                alert.addButton(withTitle: "稍后设置")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
        }
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
            // Instant visual feedback BEFORE audio engine init (user sees response in <50ms)
            self.isRecording = true
            self.updateStatusBarIcon(.recording)
            self.recordStartTime = Date()
            self.recordMenuItem.title = "⏹️ 停止录音"
            self.statusMenuItem.title = "🔴 准备中..."

            // Start duration timer immediately
            self.durationTimer?.invalidate()
            self.durationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self, let start = self.recordStartTime else { return }
                let duration = Date().timeIntervalSince(start)
                let seconds = Int(duration)
                self.statusMenuItem.title = "🔴 正在录音 \(seconds)s"
            }

            // Audio init on background to not block UI
            DispatchQueue.global(qos: .userInteractive).async {
                self.initiateRecording()
            }
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
        guard let sttClient else {
            statusMenuItem.title = "❌ STT 地址无效"
            updateStatusBarIcon(.error)
            return
        }
        statusMenuItem.title = "⏳ 正在检查服务..."
        Task {
            let result = await sttClient.healthCheck()
            await MainActor.run {
                if result.isOnline {
                    statusMenuItem.title = "✅ STT 服务在线"
                    if !isRecording && !isProcessing {
                        updateStatusBarIcon(.idle)
                    }
                } else {
                    statusMenuItem.title = "❌ STT 服务离线 - \(result.reason)"
                    if !isRecording && !isProcessing {
                        updateStatusBarIcon(.error)
                    }
                    // Auto-retry after 10 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                        self?.checkSTTService()
                    }
                }
            }
            if result.isOnline {
                AppLogger.info("服务健康检查: online (\(result.reason))")
            } else {
                AppLogger.warn("服务健康检查: offline, 原因: \(result.reason)")
            }
        }
    }

    // MARK: - Recording

    private func initiateRecording() {
        AppLogger.info("开始录音")
        do {
            try recorder.start()
            DispatchQueue.main.async {
                if self.config.soundEffect { SoundEffect.play(.start) }
                self.statusMenuItem.title = "🔴 正在录音 0s"
            }
        } catch {
            DispatchQueue.main.async {
                self.isRecording = false
                self.durationTimer?.invalidate()
                self.durationTimer = nil
                self.recordStartTime = nil
                self.updateStatusBarIcon(.error)
                self.recordMenuItem.title = "🎙️ 开始录音 (Fn)"
                let userMessage = self.userFriendlyErrorMessage(error)
                AppLogger.error("录音启动失败: \(error.localizedDescription)")
                self.showError(userMessage)
                // Recovery after error
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, !self.isRecording, !self.isProcessing else { return }
                    self.updateStatusBarIcon(.idle)
                    self.checkSTTService()
                }
            }
        }
    }

    private func stopRecordingAndTranscribe() {
        durationTimer?.invalidate()
        durationTimer = nil

        guard let sttClient else {
            isRecording = false
            recordStartTime = nil
            resetUI()
            showError("STT 服务未配置，请在设置中检查服务地址")
            return
        }
        guard let audioData = recorder.stop() else {
            isRecording = false
            recordStartTime = nil
            statusItem.button?.title = "🎤"
            updateStatusBarIcon(.idle)
            recordMenuItem.title = "🎙️ 开始录音 (Fn)"
            statusMenuItem.title = "✅ STT 服务在线"
            AppLogger.warn("停止录音后没有采集到音频数据")
            showError("录音时间太短，请按住 Fn 键后说话再松开")
            return
        }

        // Check minimum recording duration (0.5s = 16000 * 2 * 0.5 = 16000 bytes)
        let minBytes = Int(config.sampleRate) * 2 / 2 // 0.5 seconds
        if audioData.count < minBytes {
            isRecording = false
            recordStartTime = nil
            resetUI()
            showError("录音时间太短（不足 0.5 秒），请按住 Fn 键后说话再松开")
            AppLogger.warn("录音太短: \(audioData.count) 字节")
            return
        }

        let duration = recordStartTime.map { Date().timeIntervalSince($0) } ?? 0
        recordStartTime = nil
        AppLogger.info("停止录音, 采集字节数=\(audioData.count), 时长=\(String(format: "%.1f", duration))s")

        isRecording = false
        isProcessing = true
        updateStatusBarIcon(.processing)
        statusMenuItem.title = "⏳ 正在识别..."
        recordMenuItem.title = "⏳ 识别中..."
        if config.soundEffect { SoundEffect.play(.stop) }

        Task {
            do {
                let text = try await sttClient.transcribe(audioData: audioData)
                await MainActor.run {
                    if !text.isEmpty {
                        self.lastText = text
                        self.lastResultMenuItem.isEnabled = true
                        self.lastResultMenuItem.title = "📋 粘贴: \(String(text.prefix(20)))\(text.count > 20 ? "..." : "")"
                        if self.config.autoPaste {
                            TextInjector.inject(text)
                            AppLogger.info("识别成功并自动粘贴, 文本长度=\(text.count)")
                        } else {
                            AppLogger.info("识别成功, 文本长度=\(text.count)")
                        }
                        self.showNotification("✅ 识别完成", body: String(text.prefix(50)))
                    } else {
                        AppLogger.warn("识别成功但返回空文本")
                        self.showError("识别结果为空，请再试一次")
                    }
                    self.resetUI()
                }
            } catch {
                await MainActor.run {
                    let userMessage = self.userFriendlyErrorMessage(error)
                    AppLogger.error("识别失败: \(error.localizedDescription)")
                    self.showError(userMessage)
                    self.resetUI()
                    // Auto-retry service check after error
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        self?.checkSTTService()
                    }
                }
            }
        }
    }

    private func resetUI() {
        isRecording = false
        isProcessing = false
        updateStatusBarIcon(.idle)
        recordMenuItem.title = "🎙️ 开始录音 (Fn)"
        statusMenuItem.title = "✅ STT 服务在线"
    }

    // MARK: - User-Friendly Error Messages

    private func userFriendlyErrorMessage(_ error: Error) -> String {
        let desc = error.localizedDescription.lowercased()
        if desc.contains("timed out") || desc.contains("timeout") {
            return "识别超时，请检查网络连接或 STT 服务是否正常运行"
        }
        if desc.contains("network") || desc.contains("networking") || desc.contains("could not connect") {
            return "无法连接到 STT 服务，请检查网络和服务器地址设置"
        }
        if desc.contains("denied") || desc.contains("permission") {
            return "权限被拒绝，请在系统设置中检查相关权限"
        }
        if let sttError = error as? STTError {
            switch sttError {
            case .httpError(let code, _) where code == 500:
                return "STT 服务内部错误，请联系管理员"
            case .httpError(let code, _) where code == 404:
                return "STT 服务接口不存在，请检查服务地址配置"
            case .httpError(let code, _) where code == 0:
                return "无法连接到 STT 服务，请检查服务是否已启动"
            default:
                return "识别服务出错，请稍后重试"
            }
        }
        return "操作失败，请稍后重试"
    }

    // MARK: - Menu Actions

    @objc private func toggleRecord() {
        if isRecording {
            stopRecordingAndTranscribe()
        } else if !isProcessing {
            // Same instant-feedback path as hotkey
            onHotkeyPress()
        }
    }

    @objc private func pasteLast() {
        if !lastText.isEmpty {
            TextInjector.inject(lastText)
        }
    }

    @objc private func openSettings() {
        AppLogger.info("打开设置窗口")
        settingsWindowController = SettingsWindowController(config: config) { [weak self] newConfig in
            self?.applyConfig(newConfig)
        }
        settingsWindowController?.showWindow()
    }

    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "VoiceInput 使用帮助"
        alert.informativeText = """
        基本操作:
        • 按住 Fn 键开始录音，松开停止并识别
        • 也可点击菜单栏图标 → 开始录音

        功能说明:
        • 自动粘贴: 识别结果直接输入到当前光标位置
        • 录音音效: 开始/结束时播放提示音
        • 开机自启动: 系统登录时自动运行

        快捷键:
        • Fn - 按住录音/松开识别
        • Cmd+Q - 退出应用

        更多设置请打开「设置...」菜单项。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    private func applyConfig(_ newConfig: Config) {
        config = newConfig
        Config.save(newConfig)
        AppLogger.info("配置已更新: STT=\(newConfig.sttUrl), language=\(newConfig.language), mode=\(newConfig.transcribeMode.rawValue)")

        // Recreate recorder if sample rate changed
        recorder = AudioRecorder(sampleRate: newConfig.sampleRate)

        // Recreate STT client
        sttClient = STTClient(
            baseURL: newConfig.sttUrl,
            language: newConfig.language,
            sampleRate: newConfig.sampleRate,
            transcribeMode: newConfig.transcribeMode,
            backend: newConfig.backend
        )

        if sttClient == nil {
            AppLogger.error("STT 客户端初始化失败，URL 无效: \(newConfig.sttUrl)")
        }

        checkSTTService()
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
                showError("无法打开日志文件")
            } else {
                AppLogger.info("打开日志文件")
            }
        } catch {
            AppLogger.error("准备日志文件失败: \(error.localizedDescription)")
            showError("无法打开日志文件")
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
            sender.state = .off
            AppLogger.info("已关闭开机自启动")
        } else {
            do {
                try SMAppService.mainApp.register()
                sender.state = .on
                AppLogger.info("已开启开机自启动")
            } catch {
                AppLogger.error("开启开机自启动失败: \(error.localizedDescription)")
                showError("无法开启开机自启动，请检查系统设置")
            }
        }
    }

    @objc private func quitApp() {
        AppLogger.info("应用退出")
        durationTimer?.invalidate()
        pulseTimer?.invalidate()
        healthCheckTimer?.invalidate()
        hotkeyMonitor.stop()
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func showError(_ message: String) {
        AppLogger.error(message)
        updateStatusBarIcon(.error)
        showNotification("⚠️ 提示", body: message)
        // Reset icon after 5 seconds if not recording/processing
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.isRecording, !self.isProcessing else { return }
            self.updateStatusBarIcon(.idle)
        }
    }

    private func showNotification(_ title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = "VoiceInput"
        content.subtitle = title
        content.body = body
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
