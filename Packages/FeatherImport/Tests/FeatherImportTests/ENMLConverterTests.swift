import Foundation
import Testing
import FeatherCore
@testable import FeatherImport

@Suite struct ENMLConverterTests {
    let png = AttachmentFile(token: "r1", file: URL(fileURLWithPath: "/tmp/r1"), filename: "plan.png", mime: "image/png")
    let pdf = AttachmentFile(token: "r2", file: URL(fileURLWithPath: "/tmp/r2"), filename: "bill.pdf", mime: "application/pdf")

    func md(_ inner: String) -> String {
        ENMLConverter.convert("<en-note>\(inner)</en-note>", resources: ["aa": png, "bb": pdf]).markdown
    }

    @Test(arguments: [
        // div lines join into one paragraph with hard breaks; an empty div separates paragraphs
        ("<div>one</div><div>two</div><div><br/></div><div>three</div>", "one  \ntwo\n\nthree"),
        ("<p>a</p><p>b</p>", "a\n\nb"),
        ("<div>a<br/>b</div>", "a  \nb"),
        ("<h1>Title</h1><h3>Sub</h3>", "# Title\n\n### Sub"),
        ("<div><b>bold</b> <strong>strong</strong> <i>it</i> <em>em</em> <s>gone</s> <del>x</del></div>", "**bold** **strong** *it* *em* ~~gone~~ ~~x~~"),
        ("<div><u>under</u><span style=\"color:red\">red</span><font face=\"x\">font</font><sup>2</sup></div>", "underredfont2"),
        ("<div><a href=\"https://a.example/x\">link</a> <a href=\"evernote:///view/1/s1/abc/abc/\">note</a></div>",
         "[link](https://a.example/x) [note](evernote:///view/1/s1/abc/abc/)"),
        ("<ul><li>a</li><li>b</li></ul>", "- a\n- b"),
        ("<ol><li>a</li><li>b</li></ol>", "1. a\n2. b"),
        ("<div><en-todo checked=\"true\"/>done</div><div><en-todo checked=\"false\"/>open</div>", "- [x] done\n- [ ] open"),
        ("<div><en-media type=\"image/png\" hash=\"aa\"/></div>", "![plan.png](feather-import://r1)"),
        ("<div><en-media type=\"application/pdf\" hash=\"bb\"/></div>", "[bill.pdf](feather-import://r2)"),
        ("<div style=\"-en-codeblock:true\"><div>let a = 1</div><div>print(a)</div></div>", "```\nlet a = 1\nprint(a)\n```"),
        ("<pre>x = 1\ny = 2</pre>", "```\nx = 1\ny = 2\n```"),
        ("<hr/>", "---"),
        ("<div>2 * 3 = _six_ [ok] `x`</div>", "2 \\* 3 = \\_six\\_ \\[ok\\] \\`x\\`"),
        ("<div># not a heading</div>", "\\# not a heading"),
        ("<div>caf&eacute;&nbsp;bar &amp; baz</div>", "café\u{A0}bar & baz"),
    ])
    func mapping(_ enml: String, _ expected: String) {
        #expect(md(enml) == expected)
    }

    @Test func nestedListsAndTodos() {
        let out = md("<ul><li>one<ul><li><en-todo checked=\"true\"/>two<ol><li>three</li></ol></li></ul></li></ul>")
        #expect(out == "- one\n  - [x] two\n    1. three")
    }

    @Test func tableIsPreservedAndReported() {
        let r = ENMLConverter.convert("<en-note><table style=\"x\"><tr><td><b>Q1</b></td><td>120</td></tr><tr><td>Q2</td><td>a &lt; b</td></tr></table></en-note>",
                                      resources: [:])
        #expect(r.markdown == "<table>\n<tr><td>Q1</td><td>120</td></tr>\n<tr><td>Q2</td><td>a &lt; b</td></tr>\n</table>")
        #expect(r.preserved == [.table])
    }

    @Test func encryptedBlockKeptVerbatim() {
        let r = ENMLConverter.convert("<en-note><div>before</div><en-crypt hint=\"dog's name\" cipher=\"AES\">RU5DMI1mnQ==</en-crypt></en-note>", resources: [:])
        #expect(r.markdown == "before\n\n<en-crypt hint=\"dog's name\" cipher=\"AES\">RU5DMI1mnQ==</en-crypt>")
        #expect(r.preserved == [.encrypted])
    }

    @Test func unknownMediaAndBlocksAreKept() {
        let r = ENMLConverter.convert("<en-note><en-media type=\"image/png\" hash=\"ff\"/><iframe src=\"https://v.example\"></iframe></en-note>", resources: [:])
        #expect(r.markdown == "[missing attachment ff]\n\n<iframe src=\"https://v.example\"></iframe>")
        #expect(r.preserved == [.html])
    }

    @Test func malformedEnmlKeepsText() {
        let enml = "<en-note><div>first <b>bold</div><div>second &bogus; third</en-note>"
        let r = ENMLConverter.convert(enml, resources: [:])
        let positions = ["first", "bold", "second", "third"].map { r.markdown.range(of: $0)?.lowerBound }
        #expect(positions.allSatisfy { $0 != nil })
        #expect(positions.compactMap { $0 } == positions.compactMap { $0 }.sorted())
        #expect(r.preserved == [.html])
    }

    @Test func referencedAttachmentsAreReported() {
        let r = ENMLConverter.convert("<en-note><en-media type=\"image/png\" hash=\"aa\"/></en-note>", resources: ["aa": png, "bb": pdf])
        #expect(r.attachments == [png])
    }
}
