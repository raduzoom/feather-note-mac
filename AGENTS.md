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

## Dropbox (after cloning, after a build, and after git work)

```bash
for d in .git/index build Packages/*/.build; do [ -e "$d" ] && xattr -w com.dropbox.ignored 1 "$d"; done
```

## Specs and plans (when starting or finishing a phase)

Specs, crypto test vectors, designs and the roadmap live in the `universal` repo at `../universal/`. Phase workflow: `../universal/AGENTS.md`. From Phase 6, FeatherCrypto's tests read `../universal/test-vectors/`; CI then checks out the universal repo next to this one.

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

## Gotchas

- Git replaces `.git/index` with a new file on commit, reset and similar commands, and the new file has no `com.dropbox.ignored` flag. Re-run the Dropbox command above after git work.
