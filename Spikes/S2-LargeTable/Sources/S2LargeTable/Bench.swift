import AppKit
import QuartzCore

/// Drives scripted interactions from a display link and records frame pacing.
/// A frame that arrives late means the main thread was busy — that is what users feel.
final class Bench: NSObject {
    enum Step {
        case settle(seconds: Double)
        case scroll(name: String, frames: Int, jump: Bool)
        case action(name: String, run: () -> Void)
        case memory(name: String)
    }

    let variant: String
    let rows: Int
    let outPath: String?
    var results: [String: Any] = [:]
    private var steps: [Step] = []
    private var link: CADisplayLink?
    private weak var window: NSWindow?
    private var scrollView: NSScrollView?
    private var rng = SplitMix64(seed: 7)

    // per-step state
    private var current: Step?
    private var stepStart: CFTimeInterval = 0
    private var stamps: [CFTimeInterval] = []
    private var framesLeft = 0
    private var actionT0: CFTimeInterval = 0
    private var actionTicks = 0
    private var frameDuration: CFTimeInterval = 1.0 / 60
    private let stepStartOfBench = CACurrentMediaTime()

    /// Scales scroll frame counts (SwiftUI variants need `--scale 0.1` to finish at all).
    let scale: Double

    init(variant: String, rows: Int, outPath: String?, scale: Double = 1) {
        self.scale = scale
        self.variant = variant
        self.rows = rows
        self.outPath = outPath
    }

    func start(window: NSWindow, target: BenchTarget, launchSeconds: Double) {
        self.window = window
        results["variant"] = variant
        results["rows"] = target.rowCount
        results["scrollFrameScale"] = scale
        results["launchToWindowSeconds"] = launchSeconds
        scrollView = Self.findScrollView(in: window.contentView!)
        results["scrollView"] = scrollView.map { String(describing: type(of: $0.documentView!)) } ?? "not found"
        steps = [
            .settle(seconds: 1.5),
            .memory(name: "afterLoad"),
            .scroll(name: "scrollSmooth", frames: 600, jump: false),
            .settle(seconds: 0.5),
            .scroll(name: "scrollJump", frames: 120, jump: true),
            .settle(seconds: 0.5),
            .memory(name: "afterScroll"),
            .action(name: "sortSenderAsc") { target.applySort(.sender, ascending: true) },
            .settle(seconds: 1),
            .action(name: "sortSubjectAsc") { target.applySort(.subject, ascending: true) },
            .settle(seconds: 1),
            .action(name: "sortSizeDesc") { target.applySort(.size, ascending: false) },
            .settle(seconds: 1),
            .action(name: "sortDateDesc") { target.applySort(.date, ascending: false) },
            .settle(seconds: 1),
            .action(name: "selectAll") { target.selectAll() },
            .settle(seconds: 1),
            .scroll(name: "scrollSmoothSelected", frames: 300, jump: false),
            .settle(seconds: 0.5),
            .memory(name: "afterSelectAll"),
            .action(name: "filterRechnung") { target.setFilter("Rechnung") },
            .settle(seconds: 1),
            .action(name: "filterClear") { target.setFilter(nil) },
            .settle(seconds: 1),
            .memory(name: "end"),
        ]
        let l = window.contentView!.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        frameDuration = max(1.0 / 240, l.targetTimestamp - l.timestamp)
        if current == nil { advance(now) }
        guard let step = current else { return }
        switch step {
        case .settle(let seconds):
            if now - stepStart >= seconds { current = nil }
        case .scroll(let name, _, let jump):
            stamps.append(now)
            scrollStep(jump: jump)
            framesLeft -= 1
            if framesLeft <= 0 {
                results[name] = Self.pacing(stamps, frame: frameDuration)
                current = nil
            }
        case .action(let name, _):
            // Second tick after the change: SwiftUI has applied it and a frame was committed.
            actionTicks += 1
            if actionTicks == 2 {
                results[name + "Seconds"] = now - actionT0
                current = nil
            }
        case .memory:
            current = nil
        }
    }

    private func advance(_ now: CFTimeInterval) {
        guard !steps.isEmpty else { finish(); return }
        let step = steps.removeFirst()
        log("step \(step)  t=\(String(format: "%.1f", now - stepStartOfBench))s  mem=\(Self.footprintMB())MB")
        current = step
        stepStart = now
        switch step {
        case .scroll(_, let frames, _):
            stamps = []
            framesLeft = max(10, Int(Double(frames) * scale))
        case .action(_, let run):
            actionTicks = 0
            actionT0 = CACurrentMediaTime()
            run()
        case .memory(let name):
            results["memoryMB_" + name] = Self.footprintMB()
        case .settle:
            break
        }
    }

    private func scrollStep(jump: Bool) {
        guard let sv = scrollView, let doc = sv.documentView else { return }
        let clip = sv.contentView
        let maxY = max(0, doc.frame.height - clip.bounds.height)
        var y = clip.bounds.origin.y
        if jump {
            y = CGFloat(rng.pick(Int(maxY)))
        } else {
            y = min(maxY, y + 40)
        }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        sv.reflectScrolledClipView(clip)
    }

    private func finish() {
        link?.invalidate()
        link = nil
        let data = try! JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if let outPath { try? data.write(to: URL(fileURLWithPath: outPath)) }
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    static func pacing(_ stamps: [CFTimeInterval], frame: CFTimeInterval) -> [String: Any] {
        let intervals = zip(stamps.dropFirst(), stamps).map { $0 - $1 }
        guard !intervals.isEmpty else { return ["frames": 0] }
        let sorted = intervals.sorted()
        let total = stamps.last! - stamps.first!
        // Hitch time: everything beyond the frame budget, counted when a frame is >50% late.
        let hitch = intervals.reduce(0) { acc, i in i > frame * 1.5 ? acc + (i - frame) : acc }
        return [
            "frames": intervals.count,
            "frameBudgetMs": (frame * 1000).rounded2,
            "p50Ms": (sorted[sorted.count / 2] * 1000).rounded2,
            "p95Ms": (sorted[Int(Double(sorted.count - 1) * 0.95)] * 1000).rounded2,
            "maxMs": (sorted.last! * 1000).rounded2,
            "hitchMsPerSecond": (hitch * 1000 / total).rounded2,
            "lateFrames": intervals.filter { $0 > frame * 1.5 }.count,
        ]
    }

    static func findScrollView(in view: NSView) -> NSScrollView? {
        if let sv = view as? NSScrollView, sv.documentView is NSTableView { return sv }
        for sub in view.subviews { if let found = findScrollView(in: sub) { return found } }
        return nil
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? (Double(info.phys_footprint) / 1_048_576).rounded2 : -1
    }
}

extension Double {
    var rounded2: Double { (self * 100).rounded() / 100 }
}
