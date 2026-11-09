import Foundation

/// File and folder names that work on macOS, Windows and Linux (data-model.md "File and folder names").
enum FileNames {
    static let maxBytes = 200
    private static let forbidden: Set<Unicode.Scalar> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
    private static let reserved: Set<String> = {
        var s: Set<String> = ["con", "prn", "aux", "nul"]
        for i in 1...9 { s.insert("com\(i)"); s.insert("lpt\(i)") }
        return s
    }()

    static func sanitize(_ name: String) -> String {
        // Per scalar, not per Character: "/" followed by a combining accent is one Character.
        var scalars = String.UnicodeScalarView()
        for u in name.unicodeScalars {
            scalars.append(forbidden.contains(u) || u.properties.generalCategory == .control ? "-" : u)
        }
        var out = String(scalars)
        out = trim(out)
        let stem = out.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? out
        if reserved.contains(stem.lowercased()) { out += "-" }
        if out.utf8.count > maxBytes {
            var cut = ""
            for ch in out {
                if cut.utf8.count + String(ch).utf8.count > maxBytes { break }
                cut.append(ch)
            }
            out = trim(cut)   // a cut can leave a trailing space or dot
        }
        return out.isEmpty ? "Untitled" : out
    }

    private static func trim(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }

    /// The key two names collide on: APFS ignores case and Unicode normalisation.
    static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// `base + ext`, or `base (2) + ext`, … whichever is not taken yet; records the result.
    static func unique(_ base: String, ext: String, taken: inout Set<String>) -> String {
        var candidate = base + ext
        var n = 2
        while taken.contains(key(candidate)) {
            candidate = "\(base) (\(n))\(ext)"
            n += 1
        }
        taken.insert(key(candidate))
        return candidate
    }

    /// Splits `receipt.pdf` into (`receipt`, `.pdf`). A leading dot is not an extension.
    static func splitExtension(_ name: String) -> (String, String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }
}
