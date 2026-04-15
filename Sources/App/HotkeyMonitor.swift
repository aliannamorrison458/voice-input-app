import AppKit
import Foundation

/// Monitors Fn key globally via NSEvent flagsChanged.
final class HotkeyMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var fnPressed = false
    private let callback: (Bool) -> Void // true = pressed, false = released

    init(callback: @escaping (Bool) -> Void) {
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
        fnPressed = false
    }

    private func handle(event: NSEvent) {
        let isFn = event.modifierFlags.contains(.function)
        if isFn && !fnPressed {
            fnPressed = true
            callback(true)
        } else if !isFn && fnPressed {
            fnPressed = false
            callback(false)
        }
    }
}
