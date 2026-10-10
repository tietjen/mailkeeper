import Foundation
import MailKeeperKit

/// Talks to the sandboxed PDF text service (ADR-0009). One connection, reused: when the service
/// dies (its watchdog, a crash) the pending call fails and the next call relaunches it. The app
/// itself never parses a PDF.
final class PDFTextClient: AttachmentTextExtractor, @unchecked Sendable {
    static let serviceName = "de.paranoidsecurity.MailKeeper.PDFText"
    /// Longer than the service's own 60 s watchdog: normally the service ends first.
    static let timeout: TimeInterval = 90

    struct ServiceError: Error, CustomStringConvertible {
        let description: String
    }

    private let lock = NSLock()
    private var connection: NSXPCConnection?

    private func current() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }
        let new = NSXPCConnection(serviceName: Self.serviceName)
        new.remoteObjectInterface = NSXPCInterface(with: AttachmentTextService.self)
        new.invalidationHandler = { [weak self, weak new] in
            guard let self else { return }
            self.lock.lock()
            if self.connection === new { self.connection = nil }
            self.lock.unlock()
        }
        new.resume()
        connection = new
        return new
    }

    func extractText(pdf: Data) async throws -> AttachmentText {
        let connection = current()
        let once = ResumeOnce()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.attach(continuation)
                let proxy = connection.remoteObjectProxyWithErrorHandler { error in once.finish(.failure(error)) }
                guard let service = proxy as? AttachmentTextService else {
                    once.finish(.failure(ServiceError(description: "PDF service unavailable")))
                    return
                }
                service.extractText(fromPDF: pdf) { status, text, detail in
                    once.finish(.success(AttachmentText(status: AttachmentText.Status(rawValue: status) ?? .failed,
                                                        text: text, detail: detail)))
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout) {
                    once.finish(.failure(ServiceError(description: "PDF service timeout")))
                }
            }
        } onCancel: {
            once.finish(.failure(CancellationError()))  // the reply, if it still comes, is dropped
        }
    }
}

/// Resumes a continuation exactly once, whichever comes first: reply, error, timeout or
/// cancellation (which may even happen before the continuation exists).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AttachmentText, Error>?
    private var early: Result<AttachmentText, Error>?
    private var done = false

    func attach(_ c: CheckedContinuation<AttachmentText, Error>) {
        lock.lock()
        if let early, !done {
            done = true
            lock.unlock()
            c.resume(with: early)
            return
        }
        continuation = c
        lock.unlock()
    }

    func finish(_ result: Result<AttachmentText, Error>) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        guard let c = continuation else {
            early = early ?? result
            lock.unlock()
            return
        }
        done = true
        continuation = nil
        lock.unlock()
        c.resume(with: result)
    }
}
