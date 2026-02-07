import AppKit
import Foundation

final class KeyEventMonitor: ObservableObject {
    private var monitor: Any?

    func start(handler: @escaping (NSEvent) -> Bool) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if handler(event) { return nil }
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
