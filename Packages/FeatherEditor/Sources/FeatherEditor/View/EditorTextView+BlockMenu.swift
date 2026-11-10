import AppKit

/// What opened the block menu: "/" typed at `location`, or the "+" button.
enum BlockTrigger: Equatable {
    case slash(location: Int)
    case plus
}

// MARK: - Block menu (design spec "Notes" › Block menu)

extension EditorTextView {
    /// The caret's line in view coordinates: the caret's height, the text container's width.
    func caretLineRect() -> NSRect? {
        guard let tlm = textLayoutManager,
              let loc = tlm.location(tlm.documentRange.location, offsetBy: selectedRange().location) else { return nil }
        tlm.ensureLayout(for: NSTextRange(location: loc))
        var frame: CGRect?
        tlm.enumerateTextSegments(in: NSTextRange(location: loc), type: .standard, options: [.rangeNotRequired]) { _, f, _, _ in
            frame = f
            return false
        }
        guard let f = frame else { return nil }
        let width = textContainer?.size.width ?? bounds.width
        return NSRect(x: textContainerOrigin.x, y: f.minY + textContainerOrigin.y, width: width, height: max(f.height, 1))
    }

    /// The "/query" text a pick removes: the "/" and the query as typed, if the text there still is that.
    var slashTriggerRange: NSRange? {
        guard case .slash(let loc) = blockTrigger else { return nil }
        let typed = "/" + blockMenu.state.query
        let r = NSRange(location: loc, length: (typed as NSString).length)
        guard NSMaxRange(r) <= (string as NSString).length, (string as NSString).substring(with: r) == typed else { return nil }
        return r
    }

    func openBlockMenu(_ trigger: BlockTrigger) {
        blockTrigger = trigger
        blockMenu.theme = theme
        blockMenu.state = BlockMenuState()
        blockMenu.onPick = { [weak self] in self?.pickBlock($0) }
        blockMenu.onCancel = { [weak self] in self?.closeBlockMenu() }
        blockMenu.onLostFocus = { [weak self] in self?.closeBlockMenu(restoreFocus: false) }
        slashTextLength = (string as NSString).length
        let line = caretLineRect() ?? NSRect(x: textContainerOrigin.x, y: textContainerOrigin.y, width: 1, height: theme.bodyLineHeight)
        blockMenu.open(below: line, in: self, focused: trigger == .plus)
    }

    /// `restoreFocus`: give the editor focus back after the "+" panel (Esc, a pick); not when the person
    /// moved to another window.
    func closeBlockMenu(restoreFocus: Bool = true) {
        let wasFocused = blockMenu.isFocused
        blockTrigger = nil
        if blockMenu.isOpen { blockMenu.close() }
        if wasFocused, restoreFocus {
            focusRestores += 1
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(self)
        }
        scheduleBlockButtonUpdate()
    }

    /// Called after text is inserted: a "/" where a line's text begins opens the menu.
    func blockMenuDidInsert(_ inserted: String) {
        guard inserted == "/", blockTrigger == nil, mode == .live, isEditable, !hasMarkedText() else { return }
        let slashAt = selectedRange().location - 1
        let s = string as NSString
        guard slashAt >= 0, slashAt < s.length, s.character(at: slashAt) == 0x2F,
              EditorCommands.slashOpensMenu(text: string, document: parser.document, slashAt: slashAt) else { return }
        openBlockMenu(.slash(location: slashAt))
    }

    /// Called after every text change: the query is the text after the "/"; the menu closes, leaving the
    /// text as typed, when the "/" is gone or nothing matches.
    func blockMenuDidChangeText() {
        guard case .slash(let loc) = blockTrigger, !isComposing, !hasMarkedText() else { return }
        let s = string as NSString
        let caret = selectedRange().location
        guard loc < s.length, s.character(at: loc) == 0x2F, caret > loc,
              caret <= NSMaxRange(EditorCommands.line(s, at: loc).range) else { closeBlockMenu(); return }
        let query = s.substring(with: NSRange(location: loc + 1, length: caret - loc - 1))
        slashTextLength = s.length
        if query == blockMenu.state.query { return }
        guard blockMenu.state.setQuery(query) else { closeBlockMenu(); return }
        blockMenu.reload()
    }

    /// Called after the selection changes: the menu closes when the caret leaves the "/" line's tail.
    func blockMenuDidChangeSelection() {
        guard case .slash(let loc) = blockTrigger else { return }
        let s = string as NSString
        let sel = selectedRange()
        guard sel.length == 0, loc < s.length, sel.location > loc,
              sel.location <= NSMaxRange(EditorCommands.line(s, at: loc).range) else { closeBlockMenu(); return }
        // a caret move (the text didn't change) away from the query's end: the pick would cut the person's text
        if s.length == slashTextLength, sel.location != loc + 1 + (blockMenu.state.query as NSString).length { closeBlockMenu() }
    }

    /// The view scrolled: the panel follows the caret's line.
    func blockMenuFollowCaret() {
        guard blockMenu.isOpen, let line = caretLineRect() else { return }
        guard visibleRect.intersects(line) else { closeBlockMenu(); return }
        blockMenu.move(below: line, in: self)
    }

    /// Inserts a block choice at the caret: one edit for text blocks, code and divider (the "/query" goes
    /// in the same undo step).
    func pickBlock(_ choice: BlockChoice) {
        let isSlash = { if case .slash = blockTrigger { return true }; return false }()
        let trigger = slashTriggerRange
        let caret = trigger.map { NSMaxRange($0) } ?? selectedRange().location
        closeBlockMenu()
        guard isEditable, !isSlash || trigger != nil else { return }
        if let e = EditorCommands.block(choice, text: string, caret: caret, removing: trigger) {
            apply(e)
            return
        }
        // Image or file, and scan: the trigger goes now; the attachment lands later, as its own undo step.
        let (removal, location) = EditorCommands.mediaInsertionPoint(text: string, caret: caret, removing: trigger)
        if let removal { apply(removal) }
        setSelectedRange(NSRange(location: location, length: 0))
        switch choice {
        case .imageOrFile:
            let id = addAnchor(NSRange(location: location, length: 0))
            let generation = loadGeneration
            chooseFiles { [weak self] urls in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard !urls.isEmpty, self.loadGeneration == generation else { _ = self.removeAnchor(id); return }
                    self.importAndInsert(urls, anchor: id, generation: generation, cleaningUp: [], asBlock: true)
                }
            }
        case .scan:
            // macOS fills the item in (Take Photo, Scan Documents, Add Sketch); the result arrives through
            // readSelection at the caret
            pendingScan = (addAnchor(NSRange(location: location, length: 0)), loadGeneration)
            let menu = scanMenu()
            guard presentsMenus else { lastPresentedMenu = menu; return }
            let line = caretLineRect() ?? NSRect(x: textContainerOrigin.x, y: textContainerOrigin.y, width: 1, height: 1)
            menu.popUp(positioning: nil, at: NSPoint(x: line.minX, y: line.maxY), in: self)
        default:
            break
        }
    }

    /// A menu holding the Continuity Camera item.
    func scanMenu() -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Import from iPhone or iPad", action: nil, keyEquivalent: "")
        item.identifier = NSMenuItem.importFromDeviceIdentifier
        menu.addItem(item)
        return menu
    }

    // MARK: "+" button

    /// Where the "+" goes: 6 pt left of the text, centred on the caret's line. Nil when it's hidden.
    func blockButtonFrame() -> NSRect? {
        let sel = selectedRange()
        guard mode == .live, isEditable, sel.length == 0, !blockMenu.isOpen else { return nil }
        if !blockButtonShowsWithoutFocus {
            guard let window, window.isKeyWindow, window.firstResponder === self else { return nil }
        }
        let p = sel.location
        let inSource = parser.document.blocks.contains { b in
            switch b.kind {
            case .codeBlock, .unrendered: return p >= b.range.location && p <= NSMaxRange(b.range)
            default: return false
            }
        }
        guard !inSource, let line = caretLineRect() else { return nil }
        let size = BlockButton.size
        return NSRect(x: textContainerOrigin.x - 6 - size, y: (line.midY - size / 2).rounded(), width: size, height: size)
    }

    func updateBlockButton() {
        blockButtonUpdateScheduled = false
        if blockButton.superview !== self {
            blockButton.target = self
            blockButton.action = #selector(blockButtonClicked)
            addSubview(blockButton)
        }
        blockButton.tint = theme.textPlaceholder
        blockButton.hoverTint = theme.textSecondary
        if let f = blockButtonFrame() {
            blockButton.frame = f
            blockButton.isHidden = false
        } else {
            blockButton.isHidden = true
        }
    }

    /// Coalesces updates to once per run-loop turn, after layout has caught up with the edit.
    func scheduleBlockButtonUpdate() {
        guard !blockButtonUpdateScheduled else { return }
        blockButtonUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.updateBlockButton() } }
    }

    @objc func blockButtonClicked() { openBlockMenuFromButton() }

    /// Opens the focused menu (with its search field) for the caret's line.
    func openBlockMenuFromButton() {
        guard mode == .live, isEditable else { return }
        if blockMenu.isOpen { closeBlockMenu() }
        openBlockMenu(.plus)
        updateBlockButton()
    }

    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        scheduleBlockButtonUpdate()
        return ok
    }

    public override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        scheduleBlockButtonUpdate()
        return ok
    }
}

extension EditorTextView {
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for o in blockObservers { NotificationCenter.default.removeObserver(o) }
        blockObservers = []
        closeBlockMenu()
        scheduleBlockButtonUpdate()
        guard let window else { return }
        let center = NotificationCenter.default
        blockObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleBlockButtonUpdate() }
        })
        blockObservers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // the "+" menu takes key from the window on purpose; anything else closes the "/" menu
                self?.scheduleBlockButtonUpdate()
                guard let self, self.blockMenu.isOpen, !self.blockMenu.isFocused else { return }
                self.closeBlockMenu()
            }
        })
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            blockObservers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.blockMenuFollowCaret() }
            })
        }
    }
}

/// The "+" beside the caret's line.
final class BlockButton: NSButton {
    static let size: CGFloat = 20
    var tint: NSColor = .tertiaryLabelColor { didSet { if !hovering { contentTintColor = tint } } }
    var hoverTint: NSColor = .secondaryLabelColor
    private var hovering = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add a block")
        isBordered = false
        imagePosition = .imageOnly
        toolTip = "Add a block"
        setAccessibilityLabel("Add a block")
        refusesFirstResponder = true
        isHidden = true
        contentTintColor = tint
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; contentTintColor = hoverTint }
    override func mouseExited(with event: NSEvent) { hovering = false; contentTintColor = tint }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}
