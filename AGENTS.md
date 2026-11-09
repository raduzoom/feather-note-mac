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

## FeatherCore (when changing the library code)

- Every mutation goes through `Library.write`, which wraps it in one transaction together with its change-log rows. A `write` inside another `write` joins the outer transaction (import relies on this). Never write to the database outside `write`.
- FTS5 stays in sync through triggers on `notes`. Change the triggers in a new migration, never in migration 0.
- Schema changes are new entries appended to `Schema.migrations`; never edit a shipped one.

## Gotchas

- Git replaces `.git/index` with a new file on commit, reset and similar commands, and the new file has no `com.dropbox.ignored` flag. Re-run the Dropbox command above after git work.
