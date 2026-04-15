import AppKit
import Foundation
import VoiceInputCore

/// Monitors hotkey globally via NSEvent flagsChanged.
final class HotkeyMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isPressed = false
    private var hotkey: Config.Hotkey
    private let callback: (Bool) -> Void // true = pressed, false = released

    init(hotkey: Config.Hotkey = .fn, callback: @escaping (Bool) -> Void) {
        self.hotkey = hotkey
        self.callback = callback
    }

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event: event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event: event)
            return event
        }
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        isPressed = false
    }

    /// Update the hotkey without restarting the monitor
    func updateHotkey(_ newHotkey: Config.Hotkey) {
        // If currently pressed, release first
        if isPressed {
            isPressed = false
            callback(false)
        }
        hotkey = newHotkey
    }

    private func handle(event: NSEvent) {
        let expectedFlags = hotkey.modifierFlags
        let matches = event.modifierFlags.contains(expectedFlags)

        if matches && !isPressed {
            isPressed = true
            callback(true)
        } else if !matches && isPressed {
            isPressed = false
            callback(false)
        }
    }
}
