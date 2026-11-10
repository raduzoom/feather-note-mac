import FeatherCore
import FeatherCrypto
import Foundation
import Testing
@testable import FeatherSync

@Suite struct ItemCodecTests {
    let master = MasterKey.generate()
    let t0: Int64 = 1_762_696_320_123

    func note(title: String = "Groceries", body: String = "milk") -> Note {
        Note(id: ULID.generate(at: t0), title: title, body: body, notebookID: nil, tagIDs: [ULID.generate(at: t0)],
             pinned: true, created: t0, modified: t0 + 5, trashedAt: nil)
    }

    func metaJSON(_ e: EncodedItem) throws -> [String: Any] {
        let key = try ItemKey.derive(masterKey: master, itemID: e.id)
        let plain = try Envelope.open(e.meta, part: .metadata, itemID: e.id, itemKey: key)
        return try JSONSerialization.jsonObject(with: plain) as! [String: Any]
    }

    @Test func noteRoundTrip() throws {
        let n = note()
        let e = try ItemCodec.encode(note: n, extraMeta: nil, masterKey: master)
        guard case let .note(back, extra, v) = try ItemCodec.decode(type: .note, id: n.id, meta: e.meta, blob: e.blob, masterKey: master) else {
            Issue.record("not a note"); return
        }
        #expect(back == n && extra == nil && v == 1)
    }

    @Test func jsonShape() throws {
        var n = note()
        n.tagIDs = []
        let json = try metaJSON(try ItemCodec.encode(note: n, extraMeta: nil, masterKey: master))
        #expect(Set(json.keys) == ["v", "title", "notebook_id", "tag_ids", "pinned", "created", "modified", "trashed_at"])
        #expect(json["notebook_id"] is NSNull && json["trashed_at"] is NSNull && json["v"] as? Int == 1)
        #expect(json["created"] as? Int64 == t0 && json["title"] as? String == "Groceries")
    }

    @Test func unknownFieldsSurvive() throws {
        let n = note()
        let e = try ItemCodec.encode(note: n, extraMeta: #"{"color":"red"}"#, masterKey: master)
        guard case let .note(_, extra, _) = try ItemCodec.decode(type: .note, id: n.id, meta: e.meta, blob: e.blob, masterKey: master) else {
            Issue.record("not a note"); return
        }
        let again = try ItemCodec.encode(note: n, extraMeta: extra, masterKey: master)
        #expect(try metaJSON(again)["color"] as? String == "red")
    }

    @Test func newerVersionIsReported() throws {
        let n = note()
        let key = try ItemKey.derive(masterKey: master, itemID: n.id)
        let json = #"{"v":2,"title":"Future","notebook_id":null,"tag_ids":[],"pinned":false,"created":1,"modified":1,"trashed_at":null,"x":1}"#
        let meta = try Envelope.seal(Data(json.utf8), part: .metadata, itemID: n.id, itemKey: key)
        let body = try Envelope.seal(Data("b".utf8), part: .noteBody, itemID: n.id, itemKey: key)
        guard case let .note(back, _, v) = try ItemCodec.decode(type: .note, id: n.id, meta: meta, blob: body, masterKey: master) else {
            Issue.record("not a note"); return
        }
        #expect(v == 2 && back.title == "Future")
    }

    @Test func bodyBytesExact() throws {
        let body = "line one\r\nCafe\u{301}  \n\ttab"
        let n = note(body: body)
        let e = try ItemCodec.encode(note: n, extraMeta: nil, masterKey: master)
        guard case let .note(back, _, _) = try ItemCodec.decode(type: .note, id: n.id, meta: e.meta, blob: e.blob, masterKey: master) else {
            Issue.record("not a note"); return
        }
        #expect(Data(back.body.utf8) == Data(body.utf8))
    }

    @Test func wrongItemFails() throws {
        let a = note(), b = note()
        let e = try ItemCodec.encode(note: a, extraMeta: nil, masterKey: master)
        #expect(throws: CryptoError.authenticationFailed) {
            try ItemCodec.decode(type: .note, id: b.id, meta: e.meta, blob: e.blob, masterKey: master)
        }
    }

    @Test func oversizeMetaRefused() {
        let n = note(title: String(repeating: "x", count: 70_000))
        #expect(throws: CodecError.metadataTooLarge) { try ItemCodec.encode(note: n, extraMeta: nil, masterKey: master) }
    }

    @Test func otherTypesRoundTrip() throws {
        let nb = Notebook(id: ULID.generate(at: t0), name: "Recipes", parentID: ULID.generate(at: t0), created: t0, modified: t0)
        let e1 = try ItemCodec.encode(notebook: nb, extraMeta: nil, masterKey: master)
        #expect(e1.blob == nil)
        guard case let .notebook(nb2, _, _) = try ItemCodec.decode(type: .notebook, id: nb.id, meta: e1.meta, blob: nil, masterKey: master) else {
            Issue.record("notebook"); return
        }
        #expect(nb2 == nb)
        let tag = Tag(id: ULID.generate(at: t0), name: "travel", created: t0, modified: t0)
        let e2 = try ItemCodec.encode(tag: tag, extraMeta: nil, masterKey: master)
        guard case let .tag(tag2, _, _) = try ItemCodec.decode(type: .tag, id: tag.id, meta: e2.meta, blob: nil, masterKey: master) else {
            Issue.record("tag"); return
        }
        #expect(tag2 == tag)
        let content = Data("pdf bytes".utf8)
        let a = Attachment(id: ULID.generate(at: t0), filename: "r.pdf", mime: "application/pdf", size: Int64(content.count),
                           sha256: "abc", created: t0)
        let e3 = try ItemCodec.encode(attachment: a, content: content, extraMeta: nil, masterKey: master)
        guard case let .attachment(a2, data, _, _) = try ItemCodec.decode(type: .attachment, id: a.id, meta: e3.meta, blob: e3.blob, masterKey: master) else {
            Issue.record("attachment"); return
        }
        #expect(a2 == a && data == content)
        let key = try ItemKey.derive(masterKey: master, itemID: a.id)
        #expect(throws: CryptoError.authenticationFailed) { try Envelope.open(e3.blob!, part: .noteBody, itemID: a.id, itemKey: key) }
    }

    @Test func noteMetaWithoutBody() throws {
        let n = note()
        let e = try ItemCodec.encode(note: n, extraMeta: nil, masterKey: master)
        guard case let .note(back, _, _) = try ItemCodec.decode(type: .note, id: n.id, meta: e.meta, blob: nil, masterKey: master) else {
            Issue.record("not a note"); return
        }
        var expected = n
        expected.body = ""
        #expect(back == expected)
    }
}
