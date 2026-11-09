# Feather Note for Mac

A free, native, lightweight Markdown note app for macOS 15 and later. Notes stay on your Mac in a local library and export to a plain Markdown folder at any time. Optional Feather Cloud sync is end-to-end encrypted.

## Building

Needs Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate && xcodebuild test -project FeatherNote.xcodeproj -scheme FeatherNote -destination 'platform=macOS'
```

## Related repositories

- `feather-note-server`: the Feather Cloud sync server (AGPL-3.0)
- `feather-note-universal`: specs, sync protocol, crypto test vectors, designs and plans (CC BY 4.0)

## License

MIT, see [LICENSE](LICENSE).

## Trademark

The name Feather Note stays with the author. Forks must use a different name.
