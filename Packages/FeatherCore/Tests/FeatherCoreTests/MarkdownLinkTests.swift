import Testing
@testable import FeatherCore

private func dests(_ s: String) -> [String] { MarkdownLinks.destinations(in: s).map(\.destination) }

@Test func findsLinksAndImages() {
    #expect(dests("See [a](a.png) and ![b](dir/b%20c.jpg \"title\") and [c](<x y.pdf>)") == ["a.png", "dir/b%20c.jpg", "x y.pdf"])
    #expect(dests("[p](wiki/Foo_(bar).png)") == ["wiki/Foo_(bar).png"])
    #expect(dests("no links [here] (x)") == [])
}

@Test func rangesCoverOnlyTheDestination() {
    let s = "x ![a](<my img.png>) y"
    let found = MarkdownLinks.destinations(in: s)
    #expect(found.count == 1 && String(s[found[0].range]) == "my img.png")
}

@Test func codeIsSkipped() {
    let s = """
    `[a](in-code.png)` and ``[b](two.png)`` and [c](prose.png)
    ```
    [d](fenced.png)
    ```
    ~~~~
    [e](tilde.png)
    ~~~~

        [f](indented.png)

    - list
        [g](nested-list.png)
    """
    #expect(dests(s) == ["prose.png", "nested-list.png"])
}

@Test func unclosedBacktickIsLiteral() {
    #expect(dests("a ` b [c](c.png)") == ["c.png"])
}
