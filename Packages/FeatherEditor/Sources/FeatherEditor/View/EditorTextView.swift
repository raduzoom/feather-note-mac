import AppKit

public extension NSTextView {
    /// Turns off every automatic change macOS can make to typed text (Markdown must stay as typed).
    func applyNoSubstitutions() {
        isRichText = false
        importsGraphics = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        allowsUndo = true
    }
}

/// The live-preview Markdown text view. Its storage always holds the note's exact Markdown;
/// everything visual is attributes (MarkdownStyler) and layout fragments.
public final class EditorTextView: NSTextView, @preconcurrency NSTextStorageDelegate {
    public var theme: EditorTheme = .standard
    public var mode: EditorMode = .live {
        didSet { if oldValue != mode { switchMode() } }
    }
    public let imageCache = ImageCache()
    static let placeholderImageHeight: CGFloat = 96
    public private(set) var parser = IncrementalParser(text: "")
    /// Opens a link (⌘-click). A `feather://attachment/…` URL is passed as is; the app resolves it.
    public var openLink: (String) -> Void = { url in
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
    /// Turns a `feather://attachment/…` URL into the file to draw (images) or open.
    public var resolveAttachment: (String) -> URL? = { _ in nil }
    /// Imports dropped or pasted files; returns one Markdown snippet per file.
    public var importFiles: ([URL]) async -> [String] = { _ in [] }
    /// Each note gets its own undo history, so ⌘Z never reaches another note's text.
    private var noteUndo = UndoManager()
    private var idleUndoBreak: Timer?

    /// Shown while the note body is empty.
    public var placeholder = "" { didSet { needsDisplay = true } }
    /// The reading measure: side insets grow so lines never exceed it.
    public var measure: CGFloat = 560
    public var minimumSideInset: CGFloat = 40
    private var isLoading = false
    /// Pasted-image and scan files whose import hasn't finished yet.
    private var temporaryFiles: [URL] = []

    isolated deinit { cleanUpPastedFiles() }
    /// Bumped by every `load`, so work that finishes later can tell the note changed.
    private(set) var loadGeneration = 0
    /// Ranges waiting for an async insertion (an attachment import), moved by every edit.
    private var anchors: [Int: NSRange] = [:]
    private var nextAnchorID = 0
    /// Edited text waiting to be restyled (see `textStorage(_:didProcessEditing:...)`).
    private var pendingEdit: NSRange?
    private var editFlushScheduled = false
    /// Characters restyled so far; tests use it to check styling stays local.
    var restyledCharacters = 0
    private var isRestyling = false
    /// Restyling waits while an input method is composing (marked text).
    var isComposing = false
    private var pendingRestyle: NSRange?
    private let layoutDelegate = LayoutDelegate()
    /// The code block whose Copy button shows (mouse over it).
    weak var hoveredCopyFragment: DecoratedLayoutFragment?

    public static func make() -> EditorTextView {
        let tv = EditorTextView(usingTextLayoutManager: true)
        tv.applyNoSubstitutions()
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.textStorage?.delegate = tv
        tv.layoutDelegate.editor = tv
        tv.textLayoutManager?.delegate = tv.layoutDelegate
        tv.setAccessibilityLabel("Note body")
        tv.setAccessibilityIdentifier("note-body")
        return tv
    }

    /// Shows `text` as a fresh note: no undo history, styled from scratch.
    public func load(_ text: String) {
        noteUndo = UndoManager()
        loadGeneration += 1
        anchors.removeAll()
        isLoading = true
        string = text
        parser = IncrementalParser(text: text)
        setSelectedRange(NSRange(location: 0, length: 0))   // while loading, so it doesn't restyle
        isLoading = false
        restyleAll()
        noteUndo.removeAllActions()
    }

    public override var undoManager: UndoManager? { noteUndo }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let side = max(minimumSideInset, ((newSize.width - measure) / 2).rounded(.down))
        if textContainerInset.width != side { textContainerInset = NSSize(width: side, height: 8) }
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, !hasMarkedText() else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: mode == .raw ? theme.monoRaw : theme.body, .foregroundColor: theme.textPlaceholder]
        let pad = textContainer?.lineFragmentPadding ?? 0
        (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width + pad, y: textContainerInset.height), withAttributes: attrs)
    }

    /// The caret line's top, in view coordinates.
    private func caretLineTop() -> CGFloat? {
        guard let tlm = textLayoutManager,
              let loc = tlm.location(tlm.documentRange.location, offsetBy: selectedRange().location) else { return nil }
        tlm.ensureLayout(for: NSTextRange(location: loc))
        guard let frag = tlm.textLayoutFragment(for: loc) else { return nil }
        return frag.layoutFragmentFrame.minY + textContainerOrigin.y
    }

    /// Restyles for the new mode, keeping the caret's line where it was on screen.
    private func switchMode() {
        let before = caretLineTop().map { $0 - visibleRect.minY }
        restyleAll()
        textLayoutManager?.textViewportLayoutController.layoutViewport()
        guard let before, let now = caretLineTop() else { return }
        let target = NSPoint(x: visibleRect.minX, y: max(0, now - before))
        scroll(target)
        textLayoutManager?.textViewportLayoutController.layoutViewport()
    }

    // MARK: Styling

    /// Text not yet styled since the last full restyle; styled in chunks on the next run-loop turns.
    private var unstyled = IndexSet()
    private var chunkScheduled = false
    static let eagerStyleLength = 16_384
    static let styleChunkLength = 8_192

    /// True once every character has been styled (no background chunks left).
    public var isFullyStyled: Bool { unstyled.isEmpty }

    /// Restyles the whole note: the 16 KB around the caret at once, the rest in 8 KB chunks on the next
    /// run-loop turns. Styling a 50k-word note takes about 200 ms, too long to block opening it.
    public func restyleAll() {
        let length = (string as NSString).length
        unstyled = IndexSet(integersIn: 0..<length)
        let hi = min(length, max(0, selectedRange().location - Self.eagerStyleLength / 2) + Self.eagerStyleLength)
        let lo = max(0, hi - Self.eagerStyleLength)
        restyle(NSRange(location: lo, length: hi - lo))
        scheduleChunk()
    }

    private func scheduleChunk() {
        guard !unstyled.isEmpty, !chunkScheduled else { return }
        chunkScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            chunkScheduled = false
            guard let first = unstyled.rangeView.first else { return }
            restyle(NSRange(location: first.lowerBound, length: min(first.count, Self.styleChunkLength)))
            scheduleChunk()
        }
    }

    func restyle(_ range: NSRange) {
        guard let storage = textStorage, !isRestyling else { return }
        unstyled.remove(integersIn: range.location..<NSMaxRange(range))
        if isComposing {
            pendingRestyle = pendingRestyle.map { NSUnionRange($0, range) } ?? range
            return
        }
        isRestyling = true
        restyledCharacters += range.length
        defer { isRestyling = false }
        let text = storage.string
        let runs = MarkdownStyler.runs(text: text, document: parser.document, selection: selectedRange(), mode: mode,
                                       theme: theme, in: range, imageHeight: { [unowned self] in self.imageHeight(for: $0) })
        storage.beginEditing()
        for run in runs where NSMaxRange(run.range) <= storage.length {
            storage.setAttributes(run.attributes.nsAttributes, range: run.range)
        }
        storage.endEditing()
        typingAttributes = typingAttributesAtCaret()
    }

    private func typingAttributesAtCaret() -> [NSAttributedString.Key: Any] {
        [.font: mode == .raw ? theme.monoRaw : theme.body, .foregroundColor: theme.textBody]
    }

    /// The blocks the caret is in, or touches.
    func blockRanges(touching sel: NSRange) -> NSRange? {
        var out: NSRange?
        for b in parser.document.blocks where sel.location <= NSMaxRange(b.range) && NSMaxRange(sel) >= b.range.location {
            out = out.map { NSUnionRange($0, b.range) } ?? b.range
        }
        return out
    }

    // MARK: Edits

    public func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                            range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !isLoading, !isRestyling else { return }
        let old = NSRange(location: editedRange.location, length: editedRange.length - delta)
        for (id, a) in anchors {   // keep pending insertion points on the same text
            if a.location >= NSMaxRange(old) {
                anchors[id] = NSRange(location: a.location + delta, length: a.length)
            } else if NSMaxRange(a) > old.location || a.location >= old.location {
                anchors[id] = NSRange(location: NSMaxRange(editedRange), length: 0)   // the edit touched it: after the edit
            }
        }
        if !unstyled.isEmpty {   // keep the not-yet-styled ranges on the same characters
            unstyled.remove(integersIn: old.location..<NSMaxRange(old))
            unstyled.shift(startingAt: NSMaxRange(old), by: delta)
        }
        let changed = parser.apply(edit: old, replacementLength: editedRange.length, newText: textStorage.string)
        // Restyle once the caret has moved too (didChangeText, the selection change, or the next turn),
        // so a keystroke styles its paragraph once rather than twice.
        var region = NSUnionRange(changed, editedRange)
        if var p = pendingEdit {
            if p.location >= NSMaxRange(old) { p.location += delta } else if NSMaxRange(p) > old.location { p.length = max(0, p.length + delta) }
            region = NSUnionRange(p, region)
        }
        pendingEdit = region
        if !editFlushScheduled {
            editFlushScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.editFlushScheduled = false
                self?.flushPendingEdit()
            }
        }
    }

    /// Restyles the region of edits not yet restyled, if any.
    func flushPendingEdit() {
        guard let p = pendingEdit else { return }
        pendingEdit = nil
        let length = (string as NSString).length
        let clamped = NSRange(location: min(p.location, length), length: max(0, min(NSMaxRange(p), length) - min(p.location, length)))
        restyle(clamped)
    }

    /// Restyles each range once, merging those that overlap or touch.
    private func restyle(merging ranges: [NSRange]) {
        var merged: [NSRange] = []
        for r in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, r.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, r)
            } else {
                merged.append(r)
            }
        }
        merged.forEach(restyle)
    }

    // MARK: Selection

    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let old = selectedRange()
        var adjusted = ranges
        if let first = ranges.first?.rangeValue, !isRestyling {
            adjusted[0] = NSValue(range: adjustedSelection(first, from: old))
        }
        super.setSelectedRanges(adjusted, affinity: affinity, stillSelecting: stillSelecting)
        guard !isLoading, !isRestyling, !stillSelecting else { return }
        let new = selectedRange()
        // The blocks the caret left and the ones it entered, separately: a jump across the note must
        // not restyle everything in between.
        let length = (string as NSString).length
        let edit = pendingEdit.map { NSRange(location: min($0.location, length), length: max(0, min(NSMaxRange($0), length) - min($0.location, length))) }
        pendingEdit = nil
        // only the blocks at each selection's ends change (see MarkdownStyler's `touches`)
        let ends = [old, new].flatMap { [NSRange(location: $0.location, length: 0), NSRange(location: NSMaxRange($0), length: 0)] }
        restyle(merging: ([edit] + ends.map { blockRanges(touching: $0) }).compactMap { $0 })
    }

    /// Keeps a caret out of hidden syntax: it moves to the hidden run's edge in the direction of travel
    /// (the nearer edge when there's no direction). A selection that crosses hidden runs takes them whole.
    public func adjustedSelection(_ proposed: NSRange, from old: NSRange) -> NSRange {
        guard let storage = textStorage, storage.length > 0 else { return proposed }
        func hiddenRun(at i: Int) -> NSRange? {
            guard i > 0, i < storage.length else { return nil }
            var r = NSRange()
            guard storage.attribute(.featherHidden, at: i, longestEffectiveRange: &r,
                                    in: NSRange(location: 0, length: storage.length)) as? Bool == true else { return nil }
            return r.location < i ? r : nil
        }
        if proposed.length == 0 {
            guard let run = hiddenRun(at: proposed.location) else { return proposed }
            let p: Int
            if proposed.location > old.location { p = NSMaxRange(run) }
            else if proposed.location < old.location { p = run.location }
            else { p = proposed.location - run.location <= NSMaxRange(run) - proposed.location ? run.location : NSMaxRange(run) }
            return NSRange(location: p, length: 0)
        }
        var start = proposed.location, end = NSMaxRange(proposed)
        if let r = hiddenRun(at: start) { start = r.location }
        if let r = hiddenRun(at: end) { end = NSMaxRange(r) }
        return NSRange(location: start, length: end - start)
    }
}

// MARK: - Commands, clicks, pasteboard, input methods

extension EditorTextView {
    /// Applies a command's edit as one undo step.
    func apply(_ edit: EditorCommands.Edit) {
        breakUndoCoalescing()
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        setSelectedRange(edit.selection)
        breakUndoCoalescing()
    }

    private func command(_ c: (String, MarkdownDocument, NSRange) -> EditorCommands.Edit?) -> Bool {
        guard mode == .live, !hasMarkedText(), let e = c(string, parser.document, selectedRange()) else { return false }
        apply(e)
        return true
    }

    public override func insertNewline(_ sender: Any?) {
        breakUndoCoalescing()
        if !command(EditorCommands.returnKey) { super.insertNewline(sender) }
        breakUndoCoalescing()
    }

    public override func insertTab(_ sender: Any?) {
        if !command(EditorCommands.tab) { super.insertTab(sender) }
    }

    public override func insertBacktab(_ sender: Any?) {
        if !command(EditorCommands.backtab) { super.insertBacktab(sender) }
    }

    public override func deleteBackward(_ sender: Any?) {
        if !command(EditorCommands.backspaceAtItemStart) { super.deleteBackward(sender) }
    }

    /// Toggles the checkbox of the list item containing `location`.
    public func toggleCheckbox(at location: Int) {
        guard let e = EditorCommands.toggleCheckbox(text: string, document: parser.document, at: location) else { return }
        let keep = selectedRange()
        apply(e)
        setSelectedRange(keep)
    }

    public override func didChangeText() {
        super.didChangeText()
        flushPendingEdit()
        idleUndoBreak?.invalidate()
        idleUndoBreak = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.breakUndoCoalescing() }
        }
    }

    // Copy, cut and drag carry the Markdown source only, never styled text.
    public override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    public override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else { return false }
        let text = selectedRanges.map { (string as NSString).substring(with: $0.rangeValue) }.joined(separator: "\n")
        pboard.setString(text, forType: .string)
        return true
    }

    public override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        pboard.clearContents()
        return writeSelection(to: pboard, type: .string)
    }

    // Input methods: no restyling while composing, or the composition breaks.
    public override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        isComposing = true
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        // an input method cancels a composition by setting empty marked text
        if !hasMarkedText() { finishComposing() }
    }

    public override func unmarkText() {
        super.unmarkText()
        finishComposing()
    }

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        if isComposing, !hasMarkedText() { finishComposing() }
    }

    func finishComposing() {
        isComposing = false
        // the deferred restyles happened around the caret: restyle the blocks there
        let around = pendingRestyle.map { NSUnionRange($0, selectedRange()) } ?? selectedRange()
        pendingRestyle = nil
        restyle(blockRanges(touching: around) ?? around)
    }

    // MARK: Mouse

    private func containerPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)
    }

    private func fragment(at point: CGPoint) -> DecoratedLayoutFragment? {
        textLayoutManager?.textLayoutFragment(for: point) as? DecoratedLayoutFragment
    }

    private func offset(of fragment: NSTextLayoutFragment) -> Int? {
        guard let tlm = textLayoutManager else { return nil }
        return tlm.offset(from: tlm.documentRange.location, to: fragment.rangeInElement.location)
    }

    public override func mouseDown(with event: NSEvent) {
        let point = containerPoint(event)
        if let frag = fragment(at: point), let start = offset(of: frag) {
            let local = CGPoint(x: point.x - frag.layoutFragmentFrame.minX, y: point.y - frag.layoutFragmentFrame.minY)
            if let box = frag.checkboxRect, box.insetBy(dx: -4, dy: -4).contains(local), isEditable {
                toggleCheckbox(at: start)
                return
            }
            if frag.showsCopyButton, let r = frag.copyButtonRect, r.contains(local) {
                copyCodeBlock(containing: start)
                return
            }
        }
        if event.modifierFlags.contains(.command), let storage = textStorage, storage.length > 0 {
            let i = min(characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)), storage.length - 1)
            if let url = storage.attribute(.featherLink, at: i, effectiveRange: nil) as? String {
                openLink(url)
                return
            }
        }
        super.mouseDown(with: event)
    }

    func copyCodeBlock(containing location: Int) {
        for b in parser.document.blocks where location >= b.range.location && location <= NSMaxRange(b.range) {
            if case .codeBlock(_, let content) = b.kind {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString((string as NSString).substring(with: content), forType: .string)
                return
            }
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["feather"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: ["feather": true]))
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = containerPoint(event)
        var first: DecoratedLayoutFragment?
        if let frag = fragment(at: point), let start = offset(of: frag), let tlm = textLayoutManager {
            for b in parser.document.blocks where start >= b.range.location && start <= NSMaxRange(b.range) {
                if case .codeBlock(_, let content) = b.kind,
                   let loc = tlm.location(tlm.documentRange.location, offsetBy: content.location) {
                    first = tlm.textLayoutFragment(for: loc) as? DecoratedLayoutFragment
                }
            }
        }
        guard first !== hoveredCopyFragment else { return }
        hoveredCopyFragment?.showsCopyButton = false
        first?.showsCopyButton = true
        hoveredCopyFragment = first
        needsDisplay = true
    }
}

// MARK: - Attachments

extension EditorTextView {
    /// The height to reserve for an image: its size scaled to the measure once loaded, a placeholder until then.
    func imageHeight(for url: String) -> CGFloat {
        guard let file = resolveAttachment(url) else { return Self.placeholderImageHeight }
        if let image = imageCache.image(for: file), image.size.width > 0 {
            let width = min(image.size.width, measure)
            return (image.size.height * width / image.size.width).rounded()
        }
        imageCache.load(file) { [weak self] in
            self?.restyleImages(matching: url)
            self?.needsDisplay = true
        }
        return Self.placeholderImageHeight
    }

    /// What a chip shows for an attachment link.
    func chipInfo(for url: String) -> ChipInfo {
        guard let file = resolveAttachment(url), FileManager.default.fileExists(atPath: file.path) else {
            return ChipInfo(badge: "?", isPDF: false, missing: true)
        }
        let ext = file.pathExtension.uppercased()
        return ChipInfo(badge: ext.isEmpty ? "FILE" : String(ext.prefix(4)), isPDF: ext == "PDF", missing: false)
    }

    /// Inserts attachment snippets at `range`, each on its own line, as one undo step.
    public func insertAttachmentSnippets(_ snippets: [String], at range: NSRange) {
        guard !snippets.isEmpty else { return }
        let ns = string as NSString
        let start = min(range.location, ns.length)
        let atLineStart = start == 0 || [0x0A, 0x0D].contains(ns.character(at: start - 1))
        let atLineEnd = NSMaxRange(range) >= ns.length || [0x0A, 0x0D].contains(ns.character(at: NSMaxRange(range)))
        let nl = EditorCommands.previousEnding(ns, before: EditorCommands.line(ns, at: start).range.location)
        var text = snippets.joined(separator: nl)
        if !atLineStart { text = nl + text }
        if !atLineEnd { text += nl }
        apply(EditorCommands.Edit(range: range, replacement: text, selection: NSRange(location: start + (text as NSString).length, length: 0)))
    }

    /// Files first, then text, then image data: apps such as spreadsheets put a picture of the copied cells
    /// next to their text, and the text is what the person meant to paste.
    public override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        // image data before PDF: Keynote, Pages, Numbers and Preview offer both for a copied picture; a
        // Continuity Camera scan offers only the PDF
        [.fileURL] + super.readablePasteboardTypes.filter { ![.png, .tiff, .pdf].contains($0) } + [.png, .tiff, .pdf]
    }

    /// Continuity Camera (Take Photo, Scan Documents, Add Sketch) delivers images or a PDF to the view that
    /// accepts them; the result becomes an attachment like a dropped file.
    public override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                        returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let returnType, [.pdf, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg")].contains(returnType) {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    /// Restyles just the image blocks showing `url` (their reserved height changes when the image lands).
    func restyleImages(matching url: String) {
        let ranges = parser.document.blocks.compactMap { b -> NSRange? in
            if case .image(_, let u, _) = b.kind, u == url { return b.range }
            return nil
        }
        restyle(merging: ranges)
    }

    /// Removes temporary files made for pasted images and scans whose import never finished.
    func cleanUpPastedFiles() {
        for url in temporaryFiles { try? FileManager.default.removeItem(at: url) }
        temporaryFiles.removeAll()
    }

    /// The right-click menu with Continuity Camera (Take Photo, Scan Documents, Add Sketch); macOS fills the item in.
    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if !menu.items.contains(where: { $0.identifier == NSMenuItem.importFromDeviceIdentifier }) {
            let item = NSMenuItem(title: "Import from iPhone or iPad", action: nil, keyEquivalent: "")
            item.identifier = NSMenuItem.importFromDeviceIdentifier
            menu.addItem(.separator())
            menu.addItem(item)
        }
        return menu
    }

    /// "Scan 2026-11-09 10.42.pdf", local time.
    static func scanFileName(at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return "Scan \(f.string(from: date)).pdf"
    }

    /// Dropped or pasted files (and pasted image data) become attachments.
    public override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        var type = type
        if type == .pdf, pboard.availableType(from: [.png, .tiff]) != nil { type = pboard.availableType(from: [.png, .tiff])! }
        var urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        var madeFiles: [URL] = []   // temporary files made here, removed once their import finishes
        let hasText = pboard.availableType(from: [.string]) != nil
        if urls.isEmpty, !hasText, type == .pdf, let data = pboard.data(forType: .pdf) {
            let folder = FileManager.default.temporaryDirectory.appending(path: "FeatherScan-\(UUID().uuidString)", directoryHint: .isDirectory)
            let file = folder.appending(path: Self.scanFileName())
            if (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
               (try? data.write(to: file)) != nil { urls = [file]; madeFiles = [folder] }
        }
        if urls.isEmpty, !hasText, type == .png || type == .tiff, let data = pboard.data(forType: .png) ?? pboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) {
            let file = FileManager.default.temporaryDirectory.appending(path: "Pasted Image \(UUID().uuidString.prefix(4)).png")
            if (try? png.write(to: file)) != nil { urls = [file]; madeFiles = [file] }
        }
        guard !urls.isEmpty else {
            // image data next to text: paste the text
            if hasText, type == .png || type == .tiff || type == .pdf { return super.readSelection(from: pboard, type: .string) }
            return super.readSelection(from: pboard, type: type)
        }
        // The import may take a while: keep the insertion point as an anchor that later edits move, and
        // drop the result if another note was loaded meanwhile.
        let id = nextAnchorID
        nextAnchorID += 1
        anchors[id] = selectedRange()
        let generation = loadGeneration
        let importer = importFiles
        temporaryFiles += madeFiles
        Task { @MainActor [weak self] in
            let snippets = await importer(urls)
            for f in madeFiles { try? FileManager.default.removeItem(at: f) }
            self?.temporaryFiles.removeAll { madeFiles.contains($0) }
            guard let self, let range = anchors.removeValue(forKey: id), loadGeneration == generation else { return }
            let length = (string as NSString).length
            let start = min(range.location, length)
            insertAttachmentSnippets(snippets, at: NSRange(location: start, length: min(range.length, length - start)))
        }
        return true
    }
}

/// What the fragment draws for an attachment chip.
struct ChipInfo: Sendable {
    var badge: String
    var isPDF: Bool
    var missing: Bool
}
