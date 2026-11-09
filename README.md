# Feather Note for Mac

A free, native, lightweight Markdown note app for macOS 15 and later. Notes stay on your Mac in a local library and export to a plain Markdown folder at any time. Optional Feather Cloud sync is end-to-end encrypted.

## Running

Open the generated project in Xcode and run the FeatherNote scheme, or build from the command line (below). The library lives in `~/Library/Application Support/Feather Note/`.

## Building

Needs Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate && xcodebuild test -project FeatherNote.xcodeproj -scheme FeatherNote -destination 'platform=macOS'
```

## Packages

- `FeatherCore`: the local library. SQLite with full-text search, notebooks, tags, Trash, attachments, the change log sync reads, and export to and import from a Markdown folder. `fncore` is its command-line harness.
- `FeatherCrypto`, `FeatherSync`, `FeatherEditor`, `FeatherImport`: placeholders, filled in by later phases.

## Related repositories

- `feather-note-server`: the Feather Cloud sync server (AGPL-3.0)
- `feather-note-universal`: specs, sync protocol, crypto test vectors, designs and plans (CC BY 4.0)

## License

MIT, see [LICENSE](LICENSE).

## Trademark

The name Feather Note stays with the author. Forks must use a different name.
