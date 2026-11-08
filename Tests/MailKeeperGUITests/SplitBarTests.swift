import CoreGraphics
import Testing

@testable import MailKeeperGUI

@Suite("Split bar")
struct SplitBarTests {
    private func widths(_ values: [Int], _ total: CGFloat = 200) -> [CGFloat] {
        SplitBar.widths(values, total: total, gap: 2, minimum: 4)
    }

    @Test func partsShareTheWidthInProportion() {
        #expect(widths([50, 150]) == [49.5, 148.5])  // 198 after the gap
        #expect(widths([0, 753]) == [0, 200])  // nothing on the server: no gap, no sliver
        #expect(widths([753, 0]) == [200, 0])
        #expect(widths([0, 0]) == [0, 0] && widths([3, 4], 0) == [0, 0])
    }

    @Test("A small share stays visible, and the bar keeps its width (TJ: 8 of 753 on the server)")
    func smallShareGetsTheMinimum() {
        let w = widths([8, 745], 300)
        #expect(w[0] == 4)
        #expect(abs(w[0] + w[1] + 2 - 300) < 0.001)
        let three = widths([1, 1, 1000])
        #expect(three[0] == 4 && three[1] == 4 && abs(three.reduce(0, +) + 4 - 200) < 0.001)
    }
}

@MainActor
@Suite("Icon-Knöpfe der Gruppe")
struct GroupButtonTooltipTests {
    @Test("Der Tooltip nennt den Knopf, die Erklärung (falls es eine gibt) darunter")
    func tooltipIsTitleThenExplanation() {
        #expect(GroupDetailView.tooltip("Regel …", nil) == "Regel …")
        #expect(GroupDetailView.tooltip("Regel …", "") == "Regel …")
        #expect(GroupDetailView.tooltip("Aufräumen …", "mit Plan") == "Aufräumen …\nmit Plan")
    }
}
