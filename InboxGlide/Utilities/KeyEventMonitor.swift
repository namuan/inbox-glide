import AppKit
import Foundation

final class KeyEventMonitor: ObservableObject {
    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?

    func start(
        keyDownHandler: @escaping (NSEvent) -> Bool,
        keyUpHandler: @escaping (NSEvent) -> Bool
    ) {
        stop()

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if keyDownHandler(event) { return nil }
            return event
        }

        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp]) { event in
            if keyUpHandler(event) { return nil }
            return event
        }
    }

    func stop() {
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
        }
        if let keyUpMonitor {
            NSEvent.removeMonitor(keyUpMonitor)
        }
        keyDownMonitor = nil
        keyUpMonitor = nil
    }
}
