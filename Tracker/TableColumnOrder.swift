import AppKit

/// Saving and restoring the order the user dragged a table's columns into.
///
/// NSTableView has an autosave mechanism for this, but it owns widths and
/// visibility too — both of which these tables compute themselves (an elastic
/// column that absorbs the remaining space, per-tab visible sets) — so column
/// order is persisted alongside them instead, in the same defaults domain.
enum TableColumnOrder {
    /// The current left-to-right order, hidden columns included: a hidden
    /// column still has a place, and gets it back when you show it again.
    static func of(_ table: NSTableView) -> [String] {
        table.tableColumns.map(\.identifier.rawValue)
    }

    /// Rearrange `table` to match a saved order. Identifiers that no longer
    /// exist are skipped and columns the saved order never knew about — added
    /// in a later version — keep their place after the ones it did, so an old
    /// preference degrades into a partial order rather than losing a column.
    static func apply(_ order: [String]?, to table: NSTableView) {
        guard let order, !order.isEmpty else { return }
        var target = 0
        for id in order {
            guard let from = table.tableColumns.firstIndex(where: {
                $0.identifier.rawValue == id
            }) else { continue }
            if from != target { table.moveColumn(from, toColumn: target) }
            target += 1
        }
    }
}
