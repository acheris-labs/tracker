import AppKit
import Darwin

/// Activity-Monitor-style per-process inspector: identity block up top
/// (path, parent, user, % CPU), then a bordered box with Memory ·
/// Statistics · Open Files & Ports tabs, and a Quit button. All data comes
/// from public APIs; live-updated each refresh tick by ProcessListView.
/// Two-column label/value form: labels right-aligned against a spine,
/// values left-aligned after it — the layout AM's inspector uses.
private final class InspectorForm: NSView {
    private var valueFields: [NSTextField] = []

    init(labels: [String]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        var rows: [[NSView]] = []
        for l in labels {
            let label = NSTextField(labelWithString: l)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            let value = NSTextField(labelWithString: "—")
            value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            value.lineBreakMode = .byTruncatingMiddle
            valueFields.append(value)
            rows.append([label, value])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 5
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    func setValue(_ s: String, at i: Int) {
        guard i >= 0, i < valueFields.count else { return }
        valueFields[i].stringValue = s
    }
}

final class InspectorPanelController: NSWindowController, NSWindowDelegate {
    let pid: pid_t
    var onClose: (() -> Void)?

    private let pathValue = NSTextField(labelWithString: "")
    private let topGrid: InspectorForm
    private let memoryGrid: InspectorForm
    private let statsGrid: InspectorForm
    private let segment = NSSegmentedControl(
        labels: ["Memory", "Statistics", "Open Files & Ports", "Connections"],
        trackingMode: .selectOne, target: nil, action: nil)
    private let tabs = NSTabView()
    private let filesText = NSTextView()
    private let connections = ConnectionListView(showProcess: false,
                                                 defaultsKey: "inspector")
    private let workQueue = DispatchQueue(label: "net.acheris.tracker.inspector",
                                          qos: .userInitiated)
    private var filesRefreshInFlight = false
    private var connectionsRefreshInFlight = false
    private var exited = false

    /// Tab order; the segmented control's index is the raw value.
    private enum Pane: Int {
        case memory, statistics, files, connections
    }

    // Row orders; setValue indexes must match.
    private enum TopRow: Int, CaseIterable {
        case parent, user, kind, cpu, sleep
        var label: String {
            switch self {
            case .parent: return "Parent Process:"
            case .user: return "User:"
            case .kind: return "Kind:"
            case .cpu: return "% CPU:"
            case .sleep: return "Preventing Sleep:"
            }
        }
    }

    private enum MemRow: Int, CaseIterable {
        case real, virtualSize
        var label: String {
            switch self {
            case .real: return "Real Memory Size:"
            case .virtualSize: return "Virtual Memory Size:"
            }
        }
    }

    private enum StatRow: Int, CaseIterable {
        case cpuTime, threads, idle, power, energy, diskIO, diskTotal, netIO, netTotal
        var label: String {
            switch self {
            case .cpuTime: return "CPU Time:"
            case .threads: return "Threads:"
            case .idle: return "Idle Wake Ups:"
            case .power: return "Power:"
            case .energy: return "Energy:"
            case .diskIO: return "Disk Read / Write:"
            case .diskTotal: return "Bytes Read / Written:"
            case .netIO: return "Network Rcvd / Sent:"
            case .netTotal: return "Net Bytes Rcvd / Sent:"
            }
        }
    }

    init(snapshot: ProcessSnapshot, icon: NSImage) {
        self.pid = snapshot.pid
        func grid(_ labels: [String]) -> InspectorForm {
            InspectorForm(labels: labels)
        }
        topGrid = grid(TopRow.allCases.map(\.label))
        memoryGrid = grid(MemRow.allCases.map(\.label))
        statsGrid = grid(StatRow.allCases.map(\.label))

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        win.title = snapshot.name
        win.subtitle = "PID \(snapshot.pid)"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 520, height: 460)
        super.init(window: win)
        shouldCascadeWindows = false          // would defeat the autosave name
        windowFrameAutosaveName = "InspectorPanel2"
        win.delegate = self
        buildContent(window: win, snapshot: snapshot, icon: icon)
        win.center()
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    // MARK: layout

    private func buildContent(window win: NSWindow, snapshot: ProcessSnapshot,
                              icon: NSImage) {
        let root = NSView()

        // Header: icon + name, like the top of AM's inspector.
        let iconView = NSImageView()
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let nameLabel = NSTextField(labelWithString: snapshot.name)
        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        let header = NSStackView(views: [iconView, nameLabel])
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false

        // Executable path: its own row so it can truncate in the middle.
        let pathTitle = NSTextField(labelWithString: "Executable Path:")
        pathTitle.font = .systemFont(ofSize: 11)
        pathValue.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        pathValue.textColor = .secondaryLabelColor
        pathValue.lineBreakMode = .byTruncatingMiddle
        pathValue.isSelectable = true
        // Otherwise a deep path (browser helpers run 200 characters) forces the
        // whole window wider instead of truncating.
        pathValue.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathValue.stringValue = snapshot.execPath.isEmpty ? "—" : snapshot.execPath
        let pathRow = NSStackView(views: [pathTitle, pathValue])
        pathRow.orientation = .horizontal
        pathRow.spacing = 6
        pathTitle.setContentHuggingPriority(.required, for: .horizontal)
        pathTitle.setContentCompressionResistancePriority(.required, for: .horizontal)
        pathRow.translatesAutoresizingMaskIntoConstraints = false

        topGrid.translatesAutoresizingMaskIntoConstraints = false

        // Neutral segment selection matching the main window's toolbar tabs,
        // not the accent-blue default.
        segment.selectedSegmentBezelColor = .unemphasizedSelectedContentBackgroundColor
        segment.target = self
        segment.action = #selector(segmentChanged(_:))
        segment.selectedSegment = 1   // Statistics is the useful default
        segment.translatesAutoresizingMaskIntoConstraints = false

        // Tab content, wrapped in a bordered rounded box (FooterPane look).
        memoryGrid.translatesAutoresizingMaskIntoConstraints = false
        let memoryWrap = NSView()
        memoryWrap.addSubview(memoryGrid)
        NSLayoutConstraint.activate([
            memoryGrid.topAnchor.constraint(equalTo: memoryWrap.topAnchor, constant: 2),
            memoryGrid.leadingAnchor.constraint(equalTo: memoryWrap.leadingAnchor),
            memoryGrid.trailingAnchor.constraint(equalTo: memoryWrap.trailingAnchor),
        ])

        statsGrid.translatesAutoresizingMaskIntoConstraints = false
        let statsWrap = NSView()
        statsWrap.addSubview(statsGrid)
        NSLayoutConstraint.activate([
            statsGrid.topAnchor.constraint(equalTo: statsWrap.topAnchor, constant: 2),
            statsGrid.leadingAnchor.constraint(equalTo: statsWrap.leadingAnchor),
            statsGrid.trailingAnchor.constraint(equalTo: statsWrap.trailingAnchor),
        ])

        let filesScroll = NSScrollView()
        filesScroll.hasVerticalScroller = true
        filesScroll.drawsBackground = false
        filesText.isEditable = false
        filesText.isRichText = false
        filesText.drawsBackground = false
        filesText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        filesText.autoresizingMask = [.width]
        filesText.textContainerInset = NSSize(width: 0, height: 4)
        filesScroll.documentView = filesText

        for (id, view) in [("memory", memoryWrap), ("stats", statsWrap),
                           ("files", filesScroll), ("connections", connections)] {
            let item = NSTabViewItem(identifier: id)
            item.view = view
            tabs.addTabViewItem(item)
        }
        tabs.tabViewType = .noTabsNoBorder
        tabs.selectTabViewItem(at: 1)
        tabs.translatesAutoresizingMaskIntoConstraints = false

        let box = FooterPane(content: tabs, minWidth: 0, height: nil)
        // The connections table has no intrinsic height of its own; without a
        // floor the box would collapse on that tab.
        box.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        // Quit button, bottom-left like AM's inspector.
        let quit = NSButton(title: "Quit", target: self, action: #selector(quitProcess(_:)))
        quit.bezelStyle = .rounded
        quit.controlSize = .regular
        quit.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(pathRow)
        root.addSubview(topGrid)
        root.addSubview(segment)
        root.addSubview(box)
        root.addSubview(quit)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),

            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),

            pathRow.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            pathRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            pathRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            topGrid.topAnchor.constraint(equalTo: pathRow.bottomAnchor, constant: 6),
            topGrid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            topGrid.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            segment.topAnchor.constraint(equalTo: topGrid.bottomAnchor, constant: 14),
            segment.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            box.topAnchor.constraint(equalTo: segment.bottomAnchor, constant: 8),
            box.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            box.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            quit.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 10),
            quit.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            quit.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        win.contentView = root
    }

    @objc private func segmentChanged(_ s: NSSegmentedControl) {
        tabs.selectTabViewItem(at: s.selectedSegment)
        refreshSelectedPane()
    }

    /// Only the pane on screen pays for its data.
    private func refreshSelectedPane() {
        switch Pane(rawValue: segment.selectedSegment) {
        case .files:       refreshOpenFiles()
        case .connections: refreshConnections()
        default:           break
        }
    }

    @objc private func quitProcess(_ sender: Any?) {
        Darwin.kill(pid, SIGTERM)
    }

    // MARK: live updates

    /// Called each refresh tick. `snap` nil means the process is gone.
    func update(with snap: ProcessSnapshot?, parentName: String?) {
        guard let snap else {
            if !exited {
                exited = true
                window?.subtitle = "PID \(pid) · exited"
            }
            return
        }
        typealias F = ProcessListView
        topGrid.setValue(parentName.map { "\($0) (\(snap.ppid))" } ?? "\(snap.ppid)",
                         at: TopRow.parent.rawValue)
        topGrid.setValue(snap.user, at: TopRow.user.rawValue)
        topGrid.setValue(snap.isTranslated ? "Intel" : "Apple", at: TopRow.kind.rawValue)
        topGrid.setValue(String(format: "%.1f%%", snap.cpuPercent), at: TopRow.cpu.rawValue)
        topGrid.setValue(snap.preventsSleep ? "Yes" : "—", at: TopRow.sleep.rawValue)

        memoryGrid.setValue(F.formatMB(snap.rssMB), at: MemRow.real.rawValue)
        memoryGrid.setValue(F.formatMB(snap.vsizeMB), at: MemRow.virtualSize.rawValue)

        statsGrid.setValue(F.formatCPUTime(snap.cpuTimeSeconds), at: StatRow.cpuTime.rawValue)
        statsGrid.setValue("\(snap.threads)", at: StatRow.threads.rawValue)
        statsGrid.setValue("\(snap.idleWakeups)", at: StatRow.idle.rawValue)
        statsGrid.setValue(F.formatPower(snap.powerWatts), at: StatRow.power.rawValue)
        statsGrid.setValue(F.formatEnergy(snap.energyJoules), at: StatRow.energy.rawValue)
        statsGrid.setValue("\(F.formatRate(snap.diskReadBytesPerSec)) / \(F.formatRate(snap.diskWriteBytesPerSec))",
                           at: StatRow.diskIO.rawValue)
        statsGrid.setValue("\(F.formatTotal(snap.diskReadTotal)) / \(F.formatTotal(snap.diskWriteTotal))",
                           at: StatRow.diskTotal.rawValue)
        statsGrid.setValue("\(F.formatRate(snap.netRxBytesPerSec)) / \(F.formatRate(snap.netTxBytesPerSec))",
                           at: StatRow.netIO.rawValue)
        statsGrid.setValue("\(F.formatTotal(snap.netRxTotal)) / \(F.formatTotal(snap.netTxTotal))",
                           at: StatRow.netTotal.rawValue)

        refreshSelectedPane()
    }

    private func refreshOpenFiles() {
        guard !exited, !filesRefreshInFlight else { return }
        filesRefreshInFlight = true
        let pid = self.pid
        workQueue.async { [weak self] in
            let listing = Self.openFilesListing(pid: pid)
            DispatchQueue.main.async {
                guard let self else { return }
                self.filesRefreshInFlight = false
                self.filesText.string = listing
            }
        }
    }

    // MARK: connections

    private func refreshConnections() {
        guard !exited, !connectionsRefreshInFlight else { return }
        connectionsRefreshInFlight = true
        let pid = self.pid
        workQueue.async { [weak self] in
            // libproc can only read our own processes' descriptors; for the
            // rest, netstat sees the same sockets from the outside (it's a
            // subprocess, so it's the fallback rather than the default).
            let rows: [Connection]
            switch ConnectionSampler.connections(pid: pid) {
            case .ok(let own):  rows = own
            case .notPermitted: rows = SystemConnectionSampler.sample().filter { $0.pid == pid }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.connectionsRefreshInFlight = false
                self.connections.setConnections(rows)
            }
        }
    }

    // MARK: open files (libproc)

    /// Enumerate the process's file descriptors: vnode paths in full, sockets
    /// and other descriptor kinds summarized.
    private static func openFilesListing(pid: pid_t) -> String {
        guard let fds = ConnectionSampler.fdList(pid: pid) else {
            return "No descriptor info available."
        }
        let count = fds.count

        var paths: [String] = []
        var sockets: [String: Int] = [:]   // kind → count
        var other: [String: Int] = [:]
        for i in 0..<count {
            let fd = fds[i]
            switch Int32(fd.proc_fdtype) {
            case PROX_FDTYPE_VNODE:
                var vi = vnode_fdinfowithpath()
                let n = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO,
                                       &vi, Int32(MemoryLayout<vnode_fdinfowithpath>.size))
                if n == Int32(MemoryLayout<vnode_fdinfowithpath>.size) {
                    let path = withUnsafeBytes(of: &vi.pvip.vip_path) { raw -> String in
                        String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
                    }
                    if !path.isEmpty { paths.append(path) }
                }
            case PROX_FDTYPE_SOCKET:
                var si = socket_fdinfo()
                let n = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO,
                                       &si, Int32(MemoryLayout<socket_fdinfo>.size))
                let kind: String
                if n == Int32(MemoryLayout<socket_fdinfo>.size) {
                    switch si.psi.soi_kind {
                    case Int32(SOCKINFO_TCP): kind = "TCP socket"
                    case Int32(SOCKINFO_IN): kind = "UDP/IP socket"
                    case Int32(SOCKINFO_UN): kind = "Unix socket"
                    case Int32(SOCKINFO_NDRV): kind = "ndrv socket"
                    case Int32(SOCKINFO_KERN_CTL): kind = "kernel control socket"
                    case Int32(SOCKINFO_KERN_EVENT): kind = "kernel event socket"
                    default: kind = "socket"
                    }
                } else {
                    kind = "socket"
                }
                sockets[kind, default: 0] += 1
            case PROX_FDTYPE_PIPE:    other["pipe", default: 0] += 1
            case PROX_FDTYPE_KQUEUE:  other["kqueue", default: 0] += 1
            case PROX_FDTYPE_PSHM:    other["POSIX shm", default: 0] += 1
            case PROX_FDTYPE_PSEM:    other["POSIX semaphore", default: 0] += 1
            case PROX_FDTYPE_FSEVENTS: other["fsevents", default: 0] += 1
            default:                  other["other", default: 0] += 1
            }
        }

        var out: [String] = []
        out.append("\(count) open descriptors")
        out.append("")
        if !paths.isEmpty {
            out.append("Files:")
            var seen = Set<String>()
            for p in paths.sorted() where seen.insert(p).inserted {
                out.append("  \(p)")
            }
            out.append("")
        }
        if !sockets.isEmpty {
            out.append("Sockets:")
            for (k, n) in sockets.sorted(by: { $0.key < $1.key }) {
                out.append("  \(n)× \(k)")
            }
            out.append("")
        }
        if !other.isEmpty {
            out.append("Other:")
            for (k, n) in other.sorted(by: { $0.key < $1.key }) {
                out.append("  \(n)× \(k)")
            }
        }
        return out.joined(separator: "\n")
    }
}
