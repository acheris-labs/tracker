import AppKit

/// Shared chrome constants. The Chart tab keeps its custom dark panel; the
/// process tabs use system-standard colors so they track Activity Monitor's
/// appearance (and light/dark mode) for free.
enum Theme {
    // Process tables (Activity-Monitor-like).
    static let processRowHeight: CGFloat = 24
    static let processFontSize: CGFloat = 13

    // Footer with the boxed summary panes.
    static let footerHeight: CGFloat = 66
    static let footerPaneHeight: CGFloat = 52
}
