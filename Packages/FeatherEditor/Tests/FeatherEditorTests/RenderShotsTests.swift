import AppKit
import Testing
@testable import FeatherEditor

/// Renders the editor offscreen for comparison with the design boards (`desktop-editor-*`,
/// `spec-markdown-rendering`). Opt-in, and needs no screen-recording or UI-automation permission:
/// FEATHER_SHOT_DIR=<folder> swift test --package-path Packages/FeatherEditor --filter RenderShotsTests
@MainActor @Suite struct RenderShotsTests {
    static let note = """
    # Weather station build

    A small outdoor station on the shed roof, logging home every five minutes. Goal: **reliable readings through winter**. The sensor is a _Bosch BME280_ over I²C; the old ~~DHT22~~ drifted too much.

    Check the bus with `i2cdetect -y 1` and follow the [wiring guide](https://learn.example/bme280).

    [BME280-datasheet.pdf](feather://attachment/01JC8ZQ6V4N1XG2H3K5M7P9R0T)

    ## Parts

    - [x] Raspberry Pi Zero 2 W
    - [x] BME280 breakout
    - [ ] Radiation shield
    - Spare cables
      - USB-C, 2 m

    1. Power off
    2. Wire it

    ```python
    import board, adafruit_bme280
    # read every five minutes
    print("ok")
    ```

    > Mount it a metre above the roof.

    ---

    ### Notes

    Done for now.
    """

    @Test func renderEditorScreens() throws {
        guard let dir = ProcessInfo.processInfo.environment["FEATHER_SHOT_DIR"] else { return }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let bold = (Self.note as NSString).range(of: "readings through").location
        for scheme in ["light", "dark"] {
            try render(Self.note, mode: .live, caret: bold, scheme: scheme, to: out.appending(path: "editor-caret-\(scheme).png"))
            try render(Self.note, mode: .raw, caret: bold, scheme: scheme, to: out.appending(path: "editor-raw-\(scheme).png"))
            try render("", mode: .live, caret: 0, scheme: scheme, to: out.appending(path: "editor-empty-\(scheme).png"))
        }
    }

    func render(_ text: String, mode: EditorMode, caret: Int, scheme: String, to url: URL) throws {
        let size = NSSize(width: 760, height: 1_000)
        let appearance = NSAppearance(named: scheme == "dark" ? .darkAqua : .aqua)!
        // The editor panel's glass, flattened over the window background (from the boards' CSS).
        let panel = scheme == "dark" ? NSColor(srgbRed: 21 / 255, green: 32 / 255, blue: 32 / 255, alpha: 1)
                                     : NSColor(srgbRed: 240 / 255, green: 240 / 255, blue: 232 / 255, alpha: 1)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.backgroundColor = panel
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scroll.drawsBackground = true
        scroll.backgroundColor = panel
        let tv = EditorTextView.make()
        tv.placeholder = "Start writing…"
        tv.frame = scroll.bounds
        scroll.documentView = tv
        window.contentView = scroll
        tv.resolveAttachment = { _ in nil }
        tv.load(text)
        if mode == .raw { tv.mode = .raw }
        tv.setSelectedRange(NSRange(location: caret, length: 0))
        window.makeFirstResponder(tv)
        tv.textLayoutManager?.textViewportLayoutController.layoutViewport()
        appearance.performAsCurrentDrawingAppearance {
            scroll.layoutSubtreeIfNeeded()
            scroll.display()
        }
        guard let rep = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds) else { throw CocoaError(.fileWriteUnknown) }
        appearance.performAsCurrentDrawingAppearance { scroll.cacheDisplay(in: scroll.bounds, to: rep) }
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }
}
