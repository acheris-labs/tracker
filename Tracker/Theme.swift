import AppKit

/// Shared chrome constants. The Chart tab keeps its custom dark panel; the
/// process tabs use system-standard colors so they track Activity Monitor's
/// appearance (and light/dark mode) for free.
enum Theme {
    // Process tables (Activity-Monitor-like).
    static let processRowHeight: CGFloat = 24
    static let processFontSize: CGFloat = 13

    // Footer with the boxed summary panes. Sized off Activity Monitor's own
    // footer (~95pt panes in a ~110pt strip): at 52pt the graphs were a
    // couple of pixels of amplitude and the stat rows had no air between them.
    static let footerHeight: CGFloat = 104
    static let footerPaneHeight: CGFloat = 84
}
