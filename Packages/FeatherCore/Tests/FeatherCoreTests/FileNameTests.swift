import Testing
@testable import FeatherCore

@Test func fileNameRules() {
    #expect(FileNames.sanitize("a/b:c") == "a-b-c")
    #expect(FileNames.sanitize("a\\b*c?d\"e<f>g|h") == "a-b-c-d-e-f-g-h")
    #expect(FileNames.sanitize(" .x. ") == "x")
    #expect(FileNames.sanitize("CON") == "CON-")
    #expect(FileNames.sanitize("con.txt") == "con.txt-")
    #expect(FileNames.sanitize("Lpt9") == "Lpt9-")
    #expect(FileNames.sanitize("COM10") == "COM10")
    #expect(FileNames.sanitize("Console") == "Console")
    #expect(FileNames.sanitize("") == "Untitled")
    #expect(FileNames.sanitize("...") == "Untitled")
    #expect(FileNames.sanitize("\u{7}bell") == "-bell")
    #expect(FileNames.sanitize("Groceries") == "Groceries")
}

@Test func longNamesAreCutOnCharacterBoundary() {
    let long = String(repeating: "a", count: 199) + "€€€"   // € is 3 bytes
    let cut = FileNames.sanitize(long)
    #expect(cut == String(repeating: "a", count: 199))
    #expect(FileNames.sanitize(String(repeating: "é", count: 300)).utf8.count == 200)
    #expect(FileNames.sanitize(String(repeating: "a", count: 199) + " .b").utf8.count <= 200)
    #expect(!FileNames.sanitize(String(repeating: "a", count: 199) + " .b").hasSuffix(" "))
}

@Test func collisionsAreCaseInsensitive() {
    var taken: Set<String> = []
    #expect(FileNames.unique("Pasta", ext: ".md", taken: &taken) == "Pasta.md")
    #expect(FileNames.unique("pasta", ext: ".md", taken: &taken) == "pasta (2).md")
    #expect(FileNames.unique("Pasta", ext: ".md", taken: &taken) == "Pasta (3).md")
    #expect(FileNames.unique("Cafe\u{301}", ext: "", taken: &taken) == "Cafe\u{301}")
    #expect(FileNames.unique("Café", ext: "", taken: &taken) == "Café (2)")   // NFC and NFD are one name on APFS
}
