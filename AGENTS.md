# Feather Note for Mac: agent rules

Rules for AI agents in this repo. `CLAUDE.md` is a symlink to this file. The shared rules for all three Feather Note repos are in `../AGENTS.md`; global rules in `~/Dropbox/Configs/claude/AGENTS.md` still apply.

## Build and test (before saying a change works)

From this repo's root (the `.xcodeproj` is generated, never committed):

```bash
xcodegen generate && xcodebuild test -project FeatherNote.xcodeproj -scheme FeatherNote -destination 'platform=macOS'
```

Release build and universal check:

```bash
xcodebuild build -project FeatherNote.xcodeproj -scheme FeatherNote -configuration Release -derivedDataPath build -quiet && lipo -archs "build/Build/Products/Release/Feather Note.app/Contents/MacOS/Feather Note"
```

A single package: `swift test --package-path Packages/<Name>`.

FeatherCore's performance gate (search and listing 10k notes under 50 ms) is the release build; debug runs only catch large regressions:

```bash
swift test -c release --package-path Packages/FeatherCore --filter PerformanceTests
```

`fncore` is a command-line harness for FeatherCore (`init`, `add`, `list`, `search`, `export`, `import`; run it with no arguments for usage). The crash tests run it and kill it mid-commit.

```bash
swift run --package-path Packages/FeatherCore fncore list <library-dir>
```

## Dropbox (after cloning, after a build, and after git work)

```bash
for d in .git/index build Packages/*/.build; do [ -e "$d" ] && xattr -w com.dropbox.ignored 1 "$d"; done
```

## Specs and plans (when starting or finishing a phase)

Specs, crypto test vectors, designs and the roadmap live in the `universal` repo at `../universal/`. Phase workflow: `../universal/AGENTS.md`. From Phase 6, FeatherCrypto's tests read `../universal/test-vectors/`; CI then checks out the universal repo next to this one. That repo is private, so the checkout needs a read-only deploy key or fine-grained token stored as a secret in this repo.

## Decisions (when naming, versioning or signing anything)

| Decision | Value |
|---|---|
| Bundle id prefix | `app.feathernote` (app: `app.feathernote.FeatherNote`) |
| App product name | `Feather Note` |
| Version | `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml` |
| Minimum OS | macOS 15; Release builds are universal (arm64 + x86_64) |
| Swift tests | Swift Testing (`import Testing`); XCTest only for UI tests |
| Signing | Ad hoc locally, `CODE_SIGNING_ALLOWED=NO` in CI; Developer ID in Phase 10 |
| Swift packages | One per module under `Packages/`; product, target and `<Name>Tests` names are fixed because `project.yml` refers to them |
| License | MIT, copyright `The Feather Note authors` |

## The app (when changing anything under FeatherNote/)

- `AppModel` (`FeatherNote/Model/`) owns every behaviour and all UI state; views only read it and call its methods. Test behaviour through `AppModel` in `FeatherNoteTests` (Swift Testing, hosted by the app), not through views.
- The main window is an AppKit `NSWindow` hosting SwiftUI, created in `AppDelegate`. SwiftUI's `Window`/`WindowGroup` scene opened no window unless the app was launched through LaunchServices, so XCUITest and shell launches showed nothing.
- The text views (FeatherEditor's `EditorTextView`, `TitleEditor`) must keep every macOS substitution off (`applyNoSubstitutions()` / `disableSubstitutions()`); `editorTextViewHasNoSubstitutions` guards it.
- Never let SwiftUI measure a view with `.fixedSize(vertical:)` or an unbounded height: during min-size probing at near-zero widths it reports a huge height and the whole window content shifts upward.
- Launch arguments for tests only: `-FeatherLibraryPath <dir>` (never touch the real library) and `-FeatherColorScheme light|dark`. A unit-test host run always uses a temporary library.
- UI tests drive the screen. The first run may ask once to let Xcode control the computer. Screenshots of the designed screens, compared with `../universal/design/handoff/screens/`:

```bash
TEST_RUNNER_FEATHER_SHOT_LIB=<seeded library dir> xcodebuild test -project FeatherNote.xcodeproj -scheme FeatherNote -destination 'platform=macOS' -only-testing:FeatherNoteUITests/ScreenshotTests
```

  Images land in `~/Library/Containers/app.feathernote.FeatherNoteUITests.xctrunner/Data/tmp/shots/`. Seed a library with `fncore init` and `fncore import <dir> <markdown folder>`. Don't use `screencapture`: it asks the user for screen-recording permission.

## FeatherEditor (when changing the editor package)

- The text storage always holds the note's exact Markdown; nothing is ever inserted or removed for display. Styling is attributes (`MarkdownStyler`, a pure function from text + parse to runs) plus TextKit 2 layout fragments (`DecoratedLayoutFragment`) that draw bullets, checkboxes, quote and code surfaces, rules, images and chips. Hidden markers are real characters at font size 0.01.
- TextKit 2 only: never touch `layoutManager` (it switches the view to TextKit 1 for good). Use `textLayoutManager`.
- TextKit reads paragraph attributes (paragraph style, `.featherDecoration`) from a paragraph's first character, so style from the line start (`eachLine`, `fullLines`), not from the block's range.
- A fragment's frame already starts at the paragraph's indent: place decorations relative to `textStartX`, never by adding the indent again. `locationForCharacter(at:)` is unreliable for the character right after a kerned glyph.
- Styling work must stay proportional to the edit: a keystroke restyles its block once, a caret move restyles the blocks it left and entered, and a full restyle styles 16 KB around the caret and the rest in background chunks. `RestyleScopeTests` and `BackgroundStylingTests` guard this.
- Pathological input: nesting past 32 levels is neutralised before parsing (`NestingLimit`), and a block over 64 KB is shown as plain Markdown (`maxStyledBlockLength`).
- `IncrementalParser` must always equal a full parse (`matchesFullParseAfterRandomEdits`). It reparses to the end of the note for fences, HTML block openers and closers, and unclosed fences or HTML blocks before the edit; any `]:` in the note (a possible link reference definition) makes it parse in full.
- Markers reveal only at the selection's two ends (the caret), so ⌘A restyles two blocks, not the note.
- Work that finishes after an await (attachment import) must check `loadGeneration` and use an anchor moved by edits, never a range captured before the await.
- Performance gate (release; debug only catches large regressions): `swift test -c release --package-path Packages/FeatherEditor --filter PerformanceTests`. Budgets (the benchmark warms AppKit up first, as the app does at launch): open a 50k-word note < 150 ms, keystroke median < 4 ms and p99 < 16 ms, hostile inputs < 1 s. `timeout`/`alarm` around `swift test` leaves `swiftpm-testing-helper` running: `pkill -f swiftpm-testing-helper` afterwards.
- Screenshots of the editor without UI automation: `FEATHER_SHOT_DIR=<dir> swift test --package-path Packages/FeatherEditor --filter RenderShotsTests`, then compare with `../universal/design/handoff/screens/desktop-editor-*`.
- To add a corpus file: drop a `.md` file into `Packages/FeatherEditor/Tests/FeatherEditorTests/Fixtures/corpus/`. Every corpus test (round trip, incremental-vs-full parse, nesting limit untouched) picks it up.

## FeatherCore (when changing the library code)

- Every mutation goes through `Library.write`, which wraps it in one transaction together with its change-log rows. A `write` inside another `write` joins the outer transaction (import relies on this). Never write to the database outside `write`.
- FTS5 stays in sync through triggers on `notes`. Change the triggers in a new migration, never in migration 0.
- Schema changes are new entries appended to `Schema.migrations`; never edit a shipped one.

## Gotchas

- Git replaces `.git/index` with a new file on commit, reset and similar commands, and the new file has no `com.dropbox.ignored` flag. Re-run the Dropbox command above after git work.
