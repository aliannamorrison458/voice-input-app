import AppKit
import Carbon
import VoiceInputCore

/// Injects text into the current focused app via clipboard + Cmd+V.
enum TextInjector {
    static func inject(_ text: String) {
        guard !text.isEmpty else { return }

        // Check Accessibility permission (required for CGEvent.post)
        guard AXIsProcessTrusted() else {
            AppLogger.error("辅助功能权限未授权，无法注入文字")
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "无法粘贴文字"
                alert.informativeText = "VoiceInput 需要辅助功能权限才能将文字输入到其他应用。\n\n请在「系统设置 → 隐私与安全 → 辅助功能」中启用 VoiceInput，然后重新识别。\n\n识别结果已保存，可通过菜单栏「📋 粘贴上次结果」手动粘贴。"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "打开系统设置")
                alert.addButton(withTitle: "稍后设置")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
            return
        }

        // Save current clipboard
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        // Set new contents
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Async delay to ensure clipboard is ready (never block main thread)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Simulate Cmd+V
            let source = CGEventSource(stateID: .combinedSessionState)
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
            keyDown?.flags = .maskCommand
            keyDown?.post(tap: .cghidEventTap)

            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            keyUp?.flags = .maskCommand
            keyUp?.post(tap: .cghidEventTap)

            // Restore clipboard after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                pasteboard.clearContents()
                if let prev = previousContents {
                    pasteboard.setString(prev, forType: .string)
                }
            }
        }
    }
}
