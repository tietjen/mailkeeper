import Darwin
import Foundation
import MailKeeperKit
import MailKeeperPDF
import Synchronization

/// Ends the process when one PDF takes too long or memory balloons (ADR-0009). Runs on its
/// own queue, so a parser stuck in a loop cannot stop it; launchd starts a fresh service for
/// the next request and the app records the PDF as failed. The extraction's own time budget
/// (15 s, between pages) ends normal slow files first; this is the backstop for hangs.
final class Watchdog: Sendable {
    static let timeLimit: TimeInterval = 60
    static let memoryLimit = 1_536 << 20

    private let deadline = Mutex<Date?>(nil)
    private let timer: DispatchSourceTimer

    init() {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "de.paranoidsecurity.MailKeeper.PDFText.watchdog"))
    }

    func start() {
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [self] in
            guard let d = deadline.withLock({ $0 }) else { return }  // idle: nothing to guard
            if Date() > d { _exit(70) }
            if Self.footprint() > Self.memoryLimit { _exit(71) }
        }
        timer.resume()
    }

    func guarded<T>(_ work: () -> T) -> T {
        deadline.withLock { $0 = Date().addingTimeInterval(Self.timeLimit) }
        defer { deadline.withLock { $0 = nil } }
        return work()
    }

    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}

final class PDFTextService: NSObject, NSXPCListenerDelegate, AttachmentTextService, Sendable {
    static let watchdog = Watchdog()
    /// One PDF at a time: the watchdog tracks a single deadline.
    private let serial = Mutex(())

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: AttachmentTextService.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func extractText(fromPDF pdf: Data, reply: @escaping (String, String, String?) -> Void) {
        let result = serial.withLock { _ in
            Self.watchdog.guarded { autoreleasepool { PDFTextExtraction.extract(pdf) } }
        }
        reply(result.status.rawValue, result.text, result.detail)
    }
}
