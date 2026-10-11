import Foundation

/// Browser-like back/forward history for the app's views (search and cleanup drill-downs).
/// A new step drops the forward entries; `replacingCurrent` folds consecutive keystrokes of a
/// search into one step. The entry type is the app's view state.
public struct NavigationHistory<Entry: Sendable>: Sendable {
    public private(set) var entries: [Entry] = []
    /// Position of the current entry, -1 while empty.
    public private(set) var index = -1
    public let limit: Int

    public init(limit: Int = 50) {
        self.limit = max(2, limit)
    }

    public var current: Entry? { entries.indices.contains(index) ? entries[index] : nil }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index >= 0 && index < entries.count - 1 }

    public mutating func push(_ entry: Entry, replacingCurrent: Bool = false) {
        if index < entries.count - 1 { entries.removeSubrange((index + 1)...) }
        if replacingCurrent, !entries.isEmpty {
            entries[entries.count - 1] = entry
        } else {
            entries.append(entry)
        }
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        index = entries.count - 1
    }

    /// Changes the current entry in place (its selection changed, not the place).
    public mutating func updateCurrent(_ change: (inout Entry) -> Void) {
        guard entries.indices.contains(index) else { return }
        change(&entries[index])
    }

    /// Jumps to an entry (back, forward or from the history menu); nil if out of range.
    @discardableResult
    public mutating func move(to position: Int) -> Entry? {
        guard entries.indices.contains(position) else { return nil }
        index = position
        return entries[position]
    }

    public mutating func clear() {
        entries = []
        index = -1
    }
}
