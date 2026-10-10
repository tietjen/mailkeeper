import Foundation

// The PDF text service (ADR-0009): sandboxed, no network, no files — PDF bytes in, text out.
let service = PDFTextService()
PDFTextService.watchdog.start()
let listener = NSXPCListener.service()
listener.delegate = service
listener.resume()  // does not return
