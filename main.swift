// Mem: a single-window memory monitor for macOS.
//
// System totals come from host_statistics64 / sysctl, the same counters Activity
// Monitor reads. Per-process memory is the physical footprint (Activity Monitor's
// "Memory" column): read directly via proc_pid_rusage for the user's own processes,
// and from a periodic /usr/bin/top snapshot (setuid root) for processes the kernel
// won't let an unprivileged app inspect.

import AppKit
import Darwin

// MARK: - System memory

struct SystemMemory {
    var physical: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pressure: Int32 = 1     // kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical
    var freePercent: Int32 = 0  // kern.memorystatus_level
    var used: UInt64 { app + wired + compressed }
}

private let hostPort = mach_host_self()

private func sysctlValue<T: BitwiseCopyable>(_ name: String, _ initial: T) -> T {
    var value = initial
    var size = MemoryLayout<T>.size
    sysctlbyname(name, &value, &size, nil, 0)
    return value
}

private func minus(_ a: UInt64, _ b: UInt64) -> UInt64 { a > b ? a - b : 0 }

func readSystemMemory() -> SystemMemory {
    var m = SystemMemory()
    m.physical = sysctlValue("hw.memsize", UInt64(0))
    let swap = sysctlValue("vm.swapusage", xsw_usage())
    m.swapUsed = swap.xsu_used
    m.swapTotal = swap.xsu_total
    m.pressure = sysctlValue("kern.memorystatus_vm_pressure_level", Int32(1))
    m.freePercent = sysctlValue("kern.memorystatus_level", Int32(0))

    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return m }
    let page = UInt64(vm_kernel_page_size)
    // Activity Monitor's breakdown: anonymous memory minus purgeable is "App",
    // file-backed plus purgeable is "Cached Files".
    m.app = minus(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count)) * page
    m.wired = UInt64(stats.wire_count) * page
    m.compressed = UInt64(stats.compressor_page_count) * page
    m.cached = (UInt64(stats.external_page_count) + UInt64(stats.purgeable_count)) * page
    m.free = UInt64(stats.free_count) * page
    return m
}

// MARK: - Processes

struct ProcessRow {
    let pid: Int32
    let name: String
    let mine: Bool      // owned by the current user, so it can be quit without admin rights
    let footprint: UInt64
    let privileged: Bool    // root-owned: footprint came from memread (or top), not a direct read
}

final class ProcessReader {
    private struct Identity { let start: UInt64; let name: String; let mine: Bool }
    private var identities: [Int32: Identity] = [:]
    private var pids = [Int32](repeating: 0, count: 4096)
    private var topFootprints: [Int32: UInt64] = [:]
    private var topRunning = false
    private var lastTop = Date.distantPast
    /// Called after a top snapshot that filled in processes missing from this read.
    var onTopUpdate: (() -> Void)?
    private let myUID = getuid()
    /// setuid-root helper that reads every process's footprint (memread.c). When it's
    /// installed, root-owned processes cost ~2 ms per refresh instead of a 100 ms top run.
    static let helperPath = "/usr/local/libexec/memread"
    let helperInstalled: Bool = {
        var st = stat()
        return stat(ProcessReader.helperPath, &st) == 0 && st.st_uid == 0 && st.st_mode & S_ISUID != 0
    }()

    /// `snapshot: false` re-reads without starting a top run: used when a top run
    /// just finished, so one refresh can never chain into another.
    func read(snapshot: Bool = true) -> [ProcessRow] {
        var n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
        if n >= pids.count {
            pids = [Int32](repeating: 0, count: n * 2)
            n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
        }
        var rows: [ProcessRow] = []
        rows.reserveCapacity(n)
        var live = Set<Int32>()
        var needTop = false
        var missing: [(Int32, Identity)] = []
        for pid in pids.prefix(max(n, 0)) where pid > 0 {
            live.insert(pid)
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            } == 0
            let id = identity(pid, start: ok ? info.ri_proc_start_abstime : 0)
            if ok {
                rows.append(ProcessRow(pid: pid, name: id.name, mine: id.mine, footprint: info.ri_phys_footprint, privileged: false))
            } else if helperInstalled {
                missing.append((pid, id))
            } else if let f = topFootprints[pid] {
                rows.append(ProcessRow(pid: pid, name: id.name, mine: id.mine, footprint: f, privileged: true))
            } else {
                needTop = true
            }
        }
        // Prune in place: rebuilding the dictionary every refresh left freed pages behind.
        for k in identities.keys where !live.contains(k) { identities.removeValue(forKey: k) }
        if helperInstalled {
            if !missing.isEmpty {
                let footprints = runHelper()
                for (pid, id) in missing {
                    if let f = footprints[pid] { rows.append(ProcessRow(pid: pid, name: id.name, mine: id.mine, footprint: f, privileged: true)) }
                }
            }
        } else if snapshot {
            refreshTop(then: needTop ? onTopUpdate : nil)
        }
        return rows
    }

    private func identity(_ pid: Int32, start: UInt64) -> Identity {
        if let id = identities[pid], start == 0 || id.start == start { return id }
        // Name from the executable path: the innermost .app bundle if there is one
        // ("LibreWolf GPU Helper"), else the binary. Avoids NSRunningApplication,
        // which pulls LaunchServices data into memory for every app.
        var name = ""
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            let parts = String(cString: path).split(separator: "/")
            name = parts.last(where: { $0.hasSuffix(".app") }).map { String($0.dropLast(4)) } ?? parts.last.map(String.init) ?? ""
        }
        if name.isEmpty {
            var buf = [CChar](repeating: 0, count: 64)
            proc_name(pid, &buf, UInt32(buf.count))
            name = String(cString: buf)
        }
        if name.isEmpty { name = "pid \(pid)" }
        var bsd = proc_bsdshortinfo()
        let mine = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdshortinfo>.size)) > 0 && bsd.pbsi_uid == myUID
        let id = Identity(start: start, name: name, mine: mine)
        identities[pid] = id
        return id
    }

    /// Synchronous: memread finishes in ~2 ms.
    private func runHelper() -> [Int32: UInt64] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: ProcessReader.helperPath)
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        var parsed: [Int32: UInt64] = [:]
        guard (try? task.run()) != nil else { return parsed }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        // Parse "pid bytes\n" straight from the bytes: no String or substrings per line.
        parsed.reserveCapacity(600)
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var pid: Int32 = 0, val: UInt64 = 0, second = false
            for b in buf {
                switch b {
                case 48...57: if second { val = val &* 10 &+ UInt64(b - 48) } else { pid = pid &* 10 &+ Int32(b - 48) }
                case 32: second = true
                case 10: parsed[pid] = val; pid = 0; val = 0; second = false
                default: break
                }
            }
        }
        return parsed
    }

    /// Fallback without memread: one `top` snapshot in the background; its MEM column is the physical footprint.
    private func refreshTop(then done: (() -> Void)?) {
        guard !topRunning, Date().timeIntervalSince(lastTop) > 1 else { return }
        topRunning = true
        lastTop = Date()
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/top")
            task.arguments = ["-l", "1", "-s", "0", "-stats", "pid,mem"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            var parsed: [Int32: UInt64] = [:]
            if (try? task.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                    let f = line.split(separator: " ", omittingEmptySubsequences: true)
                    guard f.count >= 2, let pid = Int32(f[0]), let bytes = ProcessReader.parseTopSize(f[1]) else { continue }
                    parsed[pid] = bytes
                }
            }
            DispatchQueue.main.async {
                self.topFootprints = parsed
                self.topRunning = false
                done?()
            }
        }
    }

    static func parseTopSize(_ s: Substring) -> UInt64? {
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
        guard let unit = t.last, let n = Double(t.dropLast()) else { return nil }
        switch unit {
        case "B": return UInt64(n)
        case "K": return UInt64(n * 1024)
        case "M": return UInt64(n * 1_048_576)
        case "G": return UInt64(n * 1_073_741_824)
        default: return nil
        }
    }
}

func ownFootprint() -> UInt64 {
    var info = rusage_info_v4()
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    return info.ri_phys_footprint
}

func fmt(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1 { return String(format: "%.2f GB", gb) }
    return String(format: "%.0f MB", Double(bytes) / 1_048_576)
}

// MARK: - Drawing helpers

// Fixed sRGB colors: NSColor.systemOrange and friends load the dynamic system color
// machinery (~0.6 MB). These match the system colors closely in both appearances.
let wiredColor = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.04, alpha: 1)
let appColor = NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1)
let compressedColor = NSColor(srgbRed: 0.75, green: 0.35, blue: 0.95, alpha: 1)
let cachedColor = NSColor(srgbRed: 0.56, green: 0.56, blue: 0.58, alpha: 1)
let greenColor = NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)
let yellowColor = NSColor(srgbRed: 1.0, green: 0.80, blue: 0.0, alpha: 1)
let redColor = NSColor(srgbRed: 1.0, green: 0.27, blue: 0.23, alpha: 1)

private let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
private let digits = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
private let digitsBold = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)

private let leftStyle = NSMutableParagraphStyle()
private let rightStyle: NSMutableParagraphStyle = {
    let p = NSMutableParagraphStyle(); p.alignment = .right; p.lineBreakMode = .byTruncatingTail; return p
}()

private func drawText(_ s: String, in r: NSRect, font f: NSFont, color: NSColor, right: Bool = false) {
    leftStyle.lineBreakMode = .byTruncatingTail
    (s as NSString).draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                         attributes: [.font: f, .foregroundColor: color, .paragraphStyle: right ? rightStyle : leftStyle])
}

// MARK: - Summary (totals + bar), one drawn view

final class SummaryView: NSView {
    var memory = SystemMemory() { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let m = memory
        let (word, pColor): (String, NSColor) = m.pressure >= 4 ? ("Critical", redColor) : m.pressure >= 2 ? ("Warning", yellowColor) : ("Normal", greenColor)
        let cells: [[(String, NSColor?, String, NSColor)]] = [
            [("Used", nil, "\(fmt(m.used)) of \(fmt(m.physical))", .labelColor), ("Pressure", nil, "\(word) · \(m.freePercent)% free", pColor)],
            [("App", appColor, fmt(m.app), .labelColor), ("Wired", wiredColor, fmt(m.wired), .labelColor)],
            [("Compressed", compressedColor, fmt(m.compressed), .labelColor), ("Cached files", cachedColor, fmt(m.cached), .labelColor)],
            [("Free", nil, fmt(m.free), .labelColor), ("Swap", nil, m.swapTotal == 0 ? "none" : "\(fmt(m.swapUsed)) on disk", .labelColor)],
        ]
        let colW = (bounds.width - 24) / 2
        for (i, row) in cells.enumerated() {
            for (j, c) in row.enumerated() {
                let x = CGFloat(j) * (colW + 24), y = CGFloat(i) * 22
                var lx = x
                if let dot = c.1 {
                    dot.setFill()
                    NSBezierPath(ovalIn: NSRect(x: x, y: y + 5, width: 8, height: 8)).fill()
                    lx += 13
                }
                drawText(c.0, in: NSRect(x: lx, y: y, width: colW, height: 18), font: font, color: .secondaryLabelColor)
                drawText(c.2, in: NSRect(x: x, y: y, width: colW, height: 18), font: digitsBold, color: c.3, right: true)
            }
        }
        // Bar: wired, app, compressed, cached across physical memory.
        let r = NSRect(x: 0.5, y: 4 * 22 + 6.5, width: bounds.width - 1, height: 13)
        let clip = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        NSColor.quaternaryLabelColor.setFill()
        clip.fill()
        guard m.physical > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        var x = r.minX
        for (bytes, color) in [(m.wired, wiredColor), (m.app, appColor), (m.compressed, compressedColor), (m.cached, cachedColor)] {
            let w = r.width * CGFloat(bytes) / CGFloat(m.physical)
            color.setFill()
            NSRect(x: x, y: r.minY, width: w, height: r.height).fill()
            x += w
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - Window

final class Controller: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let window: NSWindow
    private let summary = SummaryView()
    private let table = NSTableView()
    private var shown: [ProcessRow] = []
    // Plain text field, not NSSearchField: its icon button cells cost ~0.5 MB.
    private let search = NSTextField()
    private let reader = ProcessReader()
    private var all: [ProcessRow] = []
    private var pressureSource: DispatchSourceMemoryPressure?

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Mem"
        window.minSize = NSSize(width: 440, height: 400)
        window.setFrameAutosaveName("MemWindow")
        build()
        reader.onTopUpdate = { [weak self] in self?.update(snapshot: false) }
        refresh()
        // No timer. Refresh only on events: the kernel's pressure-level changes,
        // apps launching or quitting, the window coming forward, and ⌘R.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in self?.refresh() }
        source.resume()
        pressureSource = source
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refreshSoon() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in self?.refresh() }
    }

    /// Coalesce bursts (an app launching spawns helpers) into one refresh.
    private var pending = false
    private func refreshSoon() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.pending = false; self?.refresh() }
    }

    private func build() {
        // Plain frames and autoresizing; no Auto Layout engine.
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 680))
        let w = content.bounds.width, h = content.bounds.height
        summary.frame = NSRect(x: 16, y: h - 14 - 110, width: w - 32, height: 110)
        summary.autoresizingMask = [.width, .minYMargin]
        search.frame = NSRect(x: 16, y: h - 14 - 110 - 8 - 24, width: w - 32, height: 24)
        search.autoresizingMask = [.width, .minYMargin]
        search.placeholderString = "Filter processes (Esc clears)"
        search.bezelStyle = .roundedBezel
        search.delegate = self
        for (id, title, width, ascending) in [("name", "Process", 270.0, true), ("memory", "Memory", 90.0, false),
                                              ("pid", "PID", 60.0, true)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            col.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: ascending)
            if id != "name" { col.headerCell.alignment = .right }
            table.addTableColumn(col)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "memory", ascending: false)]
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.style = .plain
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: w, height: h - 14 - 110 - 8 - 24 - 8))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.autoresizingMask = [.width, .height]
        for v in [summary, search, scroll] { content.addSubview(v) }
        window.contentView = content
        window.initialFirstResponder = table
    }

    @objc func refresh() { update(snapshot: true) }

    private func update(snapshot: Bool) {
        // Nothing to look at: skip the work entirely.
        guard window.occlusionState.contains(.visible) else { return }
        summary.memory = readSystemMemory()
        all = reader.read(snapshot: snapshot)
        apply()
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        window.subtitle = "\(all.count) processes · this app \(fmt(ownFootprint())) · updated \(time) · ⌘R"
    }

    private func apply() {
        let selected = table.selectedRow >= 0 && table.selectedRow < shown.count ? shown[table.selectedRow].pid : nil
        let q = search.stringValue.lowercased()
        shown = q.isEmpty ? all : all.filter { $0.name.lowercased().contains(q) || String($0.pid) == q }
        let d = table.sortDescriptors.first ?? NSSortDescriptor(key: "memory", ascending: false)
        let key = d.key ?? "memory", asc = d.ascending
        shown.sort { a, b in
            let ordered: Bool
            switch key {
            case "name": ordered = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case "pid": ordered = a.pid < b.pid
            default: ordered = a.footprint < b.footprint
            }
            return asc ? ordered : !ordered
        }
        table.reloadData()
        if let selected, let i = shown.firstIndex(where: { $0.pid == selected }) {
            table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        }
    }

    // Table: plain NSTextField cells, reused; only visible rows get views.

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { apply() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField) ?? {
            let f = NSTextField(labelWithString: "")
            f.identifier = id
            f.lineBreakMode = .byTruncatingTail
            if id.rawValue != "name" {
                f.alignment = .right
                f.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            }
            return f
        }()
        let p = shown[row]
        switch id.rawValue {
        case "name": cell.stringValue = p.name
        case "memory": cell.stringValue = fmt(p.footprint)
        default: cell.stringValue = String(p.pid)
        }
        cell.textColor = p.privileged && id.rawValue == "memory" ? .secondaryLabelColor : .labelColor
        return cell
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard row >= 0, row < shown.count else { return }
        for item in self.menu(for: shown[row]).items { item.menu?.removeItem(item); menu.addItem(item) }
    }

    func controlTextDidChange(_ obj: Notification) { apply() }

    // Esc clears the filter, as it did with the search field.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        search.stringValue = ""
        apply()
        return true
    }

    // Context menu: quit / force quit

    private func menu(for p: ProcessRow) -> NSMenu {
        let menu = NSMenu()
        let quit = menu.addItem(withTitle: "Quit \(p.name)", action: #selector(quitProcess(_:)), keyEquivalent: "")
        let force = menu.addItem(withTitle: "Force Quit \(p.name)", action: #selector(forceQuitProcess(_:)), keyEquivalent: "")
        for item in [quit, force] { item.target = self; item.representedObject = p.pid }
        return menu
    }

    @objc private func quitProcess(_ sender: NSMenuItem) { terminate(sender, force: false) }
    @objc private func forceQuitProcess(_ sender: NSMenuItem) { terminate(sender, force: true) }

    private func terminate(_ sender: NSMenuItem, force: Bool) {
        guard let pid = sender.representedObject as? Int32, let p = all.first(where: { $0.pid == pid }) else { return }
        let confirm = NSAlert()
        confirm.messageText = "\(force ? "Force quit" : "Quit") \(p.name) (PID \(pid))?"
        confirm.informativeText = force ? "Unsaved work in this process will be lost." : "It will be asked to exit."
        confirm.addButton(withTitle: force ? "Force Quit" : "Quit")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        let ok: Bool
        if let app = NSRunningApplication(processIdentifier: pid) {
            ok = force ? app.forceTerminate() : app.terminate()
        } else {
            ok = kill(pid, force ? SIGKILL : SIGTERM) == 0
        }
        if !ok {
            let err = NSAlert()
            err.messageText = "Couldn't quit \(p.name)"
            err.informativeText = p.mine ? String(cString: strerror(errno)) : "It belongs to the system or another user; only an administrator can stop it."
            err.runModal()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refresh() }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: Controller!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let main = NSMenu()
        let appItem = main.addItem(withTitle: "", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Refresh", action: #selector(Controller.refresh), keyEquivalent: "r")
        appMenu.addItem(withTitle: "Quit Mem", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main

        controller = Controller()
        controller.window.center()
        controller.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                               object: controller.window, queue: .main) { [weak self] _ in self?.controller.refresh() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// `mem --dump`: print what the window would show, for checking numbers from a shell.
if CommandLine.arguments.contains("--dump") {
    let m = readSystemMemory()
    print("used \(fmt(m.used)) of \(fmt(m.physical)) | app \(fmt(m.app)) wired \(fmt(m.wired)) compressed \(fmt(m.compressed)) cached \(fmt(m.cached)) free \(fmt(m.free)) | swap \(fmt(m.swapUsed))/\(fmt(m.swapTotal)) | pressure \(m.pressure) free% \(m.freePercent)")
    let reader = ProcessReader()
    _ = reader.read()
    Thread.sleep(forTimeInterval: 0.6)   // let the top snapshot land
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    let rows = reader.read().sorted { $0.footprint > $1.footprint }
    print("\(rows.count) processes (\(rows.filter { $0.privileged }.count) root-owned, via \(reader.helperInstalled ? "memread" : "top"))")
    for p in rows.prefix(12) { print(String(format: "%6d  %-28@ %10@%@", p.pid, p.name as NSString, fmt(p.footprint) as NSString, p.privileged ? " (top)" : "")) }
    print("self \(fmt(ownFootprint()))")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
