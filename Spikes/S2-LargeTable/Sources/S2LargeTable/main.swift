import AppKit
import QuartzCore
import SwiftUI

// Usage: S2LargeTable --variant array|lazy|appkit [--rows 200000] [--auto] [--out results.json]

let processStart = CACurrentMediaTime()
let args = CommandLine.arguments
func arg(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var bench: Bench?
    var target: BenchTarget?
    var store: Store?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let variant = arg("--variant") ?? "lazy"
        let rows = Int(arg("--rows") ?? "200000") ?? 200_000
        let store = try! Store(rows: rows)
        self.store = store

        let t0 = CACurrentMediaTime()
        let root: AnyView
        switch variant {
        case "array":
            let m = ArrayModel(store: store); target = m; root = AnyView(ArrayTableView(model: m))
        case "appkit":
            let m = AppKitModel(store: store); target = m; root = AnyView(AppKitTableView(model: m))
        default:
            let m = LazyModel(store: store); target = m; root = AnyView(LazyTableView(model: m))
        }
        let loadSeconds = CACurrentMediaTime() - t0
        log("\(variant): model ready in \(String(format: "%.3f", loadSeconds))s (\(target!.rowCount) rows)")

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "S2 — \(variant) — \(rows) rows"
        w.contentView = NSHostingView(rootView: root)
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window = w

        guard args.contains("--auto") else { return }
        // Let the first layout pass happen, then start measuring.
        DispatchQueue.main.async { [self] in
            let launch = CACurrentMediaTime() - processStart
            let b = Bench(variant: variant, rows: rows, outPath: arg("--out"), scale: Double(arg("--scale") ?? "1") ?? 1)
            b.results["modelLoadSeconds"] = loadSeconds.rounded2
            bench = b
            b.start(window: w, target: target!, launchSeconds: launch.rounded2)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
