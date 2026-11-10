import AppKit

/// The block menu's query, matching choices and selected row.
struct BlockMenuState: Equatable {
    static let maxQueryLength = 24

    var query = ""
    var items = BlockChoice.allCases
    var selected = 0

    var selection: BlockChoice? { items.indices.contains(selected) ? items[selected] : nil }

    /// Filters by `query` and selects the first row. False, leaving the state as it was, when the menu should
    /// close instead: nothing matches, the query starts with a space, or it's too long.
    mutating func setQuery(_ query: String) -> Bool {
        guard query.count <= Self.maxQueryLength, !query.hasPrefix(" ") else { return false }
        let matches = BlockChoice.matching(query)
        guard !matches.isEmpty else { return false }
        self.query = query
        items = matches
        selected = 0
        return true
    }

    /// Moves the selection, wrapping at either end.
    mutating func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = ((selected + delta) % items.count + items.count) % items.count
    }
}

/// The block menu: a small panel of choices below the caret's line. Opened by "/" it never takes focus (the
/// editor keeps typing the query and forwards arrows, Return and Esc); opened by "+" it is focused and has
/// its own search field.
@MainActor final class BlockMenuController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static let width: CGFloat = 260
    static let rowHeight: CGFloat = 30
    static let maxVisibleRows = 8
    static let searchHeight: CGFloat = 36

    var state = BlockMenuState()
    private(set) var isOpen = false
    private(set) var isFocused = false
    var theme: EditorTheme = .standard
    var onPick: (BlockChoice) -> Void = { _ in }
    var onCancel: () -> Void = {}
    /// The focused ("+") panel lost key to another window: close without taking focus back.
    var onLostFocus: () -> Void = {}

    private(set) var panel: BlockMenuPanel?
    private let table = BlockMenuTable()
    let search = NSSearchField()

    /// Opens below `lineRect` (in `view`'s coordinates), or above it when the screen has no room below.
    func open(below lineRect: NSRect, in view: NSView, focused: Bool) {
        isOpen = true
        isFocused = focused
        search.stringValue = ""
        guard let window = view.window else { return }   // tests: state only
        let panel = self.panel ?? makePanel()
        panel.focusable = focused
        panel.appearance = window.effectiveAppearance
        line = window.convertToScreen(view.convert(lineRect, to: nil))
        screen = window.screen
        reload()
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        if focused {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(search)
        } else {
            panel.orderFront(nil)
        }
    }

    /// Moves an open panel to follow the caret's line (the view scrolled).
    func move(below lineRect: NSRect, in view: NSView) {
        guard isOpen, let panel, let window = view.window else { return }
        line = window.convertToScreen(view.convert(lineRect, to: nil))
        layout(panel)
    }

    func close() {
        isOpen = false
        isFocused = false
        state = BlockMenuState()
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func reload() {
        guard let panel else { return }
        layout(panel)
        table.reloadData()
        if state.selection != nil {
            table.selectRowIndexes([state.selected], byExtendingSelection: false)
            table.scrollRowToVisible(state.selected)
        }
    }

    /// Menu keys: Up and Down move (wrapping), Return picks, Esc closes. False for any other command.
    func handle(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): state.move(-1); reload()
        case #selector(NSResponder.moveDown(_:)): state.move(1); reload()
        case #selector(NSResponder.insertNewline(_:)): if let c = state.selection { onPick(c) }
        case #selector(NSResponder.cancelOperation(_:)): onCancel()
        default: return false
        }
        return true
    }

    // MARK: Panel

    private func makePanel() -> BlockMenuPanel {
        let panel = BlockMenuPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.onResignKey = { [weak self] in
            guard let self, isFocused else { return }
            onLostFocus()
        }

        let glass = NSVisualEffectView()
        glass.material = .menu
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 8
        glass.layer?.masksToBounds = true

        search.placeholderString = "Filter blocks"
        search.delegate = self
        search.focusRingType = .none
        search.sendsSearchStringImmediately = true
        search.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("block"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.setAccessibilityLabel("Blocks")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        glass.addSubview(search)
        glass.addSubview(scroll)
        let searchTop = search.topAnchor.constraint(equalTo: glass.topAnchor, constant: 8)
        NSLayoutConstraint.activate([
            searchTop,
            search.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 8),
            search.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -8),
            scroll.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -4),
        ])
        searchConstraint = scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 4)
        plainConstraint = scroll.topAnchor.constraint(equalTo: glass.topAnchor, constant: 4)
        panel.contentView = glass
        self.panel = panel
        return panel
    }

    private var searchConstraint: NSLayoutConstraint?
    private var plainConstraint: NSLayoutConstraint?

    /// The caret's line on screen, and its screen: where the panel hangs.
    private var line = NSRect.zero
    private var screen: NSScreen?

    /// Sizes the panel to its rows (at most `maxVisibleRows`) and hangs it below the line, or above it.
    private func layout(_ panel: NSPanel) {
        search.isHidden = !isFocused
        searchConstraint?.isActive = isFocused
        plainConstraint?.isActive = !isFocused
        let rows = CGFloat(min(Self.maxVisibleRows, max(1, state.items.count)))
        let height = rows * Self.rowHeight + 8 + (isFocused ? Self.searchHeight : 0)
        var origin = NSPoint(x: line.minX, y: line.minY - height - 4)
        if let visible = screen?.visibleFrame {
            if origin.y < visible.minY { origin.y = line.maxY + 4 }
            origin.x = min(max(origin.x, visible.minX), visible.maxX - Self.width)
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: Self.width, height: height)), display: true)
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard state.items.indices.contains(row) else { return }
        state.selected = row
        onPick(state.items[row])
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { state.items.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = BlockMenuRowView()
        v.fill = theme.accent.withAlphaComponent(0.18)
        return v
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let choice = state.items[row]
        let icon = NSImageView(image: NSImage(systemSymbolName: choice.symbolName, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = theme.textSecondary
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let title = NSTextField(labelWithString: choice.title)
        title.font = .systemFont(ofSize: 13)
        title.textColor = theme.textPrimary
        let hint = NSTextField(labelWithString: choice.hint)
        hint.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        hint.textColor = theme.textSecondary
        hint.alignment = .right
        hint.setContentHuggingPriority(.required, for: .horizontal)
        let stack = NSStackView(views: [icon, title, NSView(), hint])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 12)
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.button)
        stack.setAccessibilityLabel(choice.title)
        return stack
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if table.selectedRow >= 0 { state.selected = table.selectedRow }
    }

    // MARK: Search field (focused mode)

    func controlTextDidChange(_ obj: Notification) {
        let q = search.stringValue
        if !state.setQuery(q) {
            // nothing typed into the note: keep the panel, show no rows
            state.query = q
            state.items = q.isEmpty ? BlockChoice.allCases : BlockChoice.matching(q)
            state.selected = 0
        }
        reload()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        handle(commandSelector)
    }
}

/// The menu's window: focusable only when opened from the "+" button.
final class BlockMenuPanel: NSPanel {
    var focusable = false
    var onResignKey: () -> Void = {}
    override var canBecomeKey: Bool { focusable }
    override func resignKey() {
        super.resignKey()
        onResignKey()
    }
}

/// Rows take the first click even while the panel isn't key ("/" mode).
final class BlockMenuTable: NSTableView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class BlockMenuRowView: NSTableRowView {
    var fill: NSColor = .selectedContentBackgroundColor
    override func drawSelection(in dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
    override var isEmphasized: Bool { get { false } set {} }
}
