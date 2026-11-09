import Foundation
import Testing
@testable import FeatherCore

@Test func sameBytesStoredOnce() async throws {
    let lib = try TestLibrary.open()
    let data = Data("hello".utf8)
    let a = try await lib.addAttachment(data: data, filename: "a.txt")
    let b = try await lib.addAttachment(data: data, filename: "b.txt")
    #expect(a.id != b.id && a.sha256 == b.sha256)
    let url = try #require(try await lib.attachmentFileURL(a.id))
    #expect(try await lib.attachmentFileURL(b.id) == url)
    #expect(try Data(contentsOf: url) == data)
    let files = try FileManager.default.subpathsOfDirectory(atPath: lib.directory.appending(path: "attachments").path)
    #expect(files.filter { $0.contains("/") }.count == 1)
    #expect(try await lib.attachments().count == 2)
    #expect(try await lib.changes(after: 0).allSatisfy { $0.itemType == .attachment && $0.bodyChanged })
}

@Test func sha256IsLowercaseHexOfContent() async throws {
    let lib = try TestLibrary.open()
    let a = try await lib.addAttachment(data: Data("abc".utf8), filename: "abc.txt")
    #expect(a.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(a.size == 3 && a.created == TestLibrary.t0)
    #expect(try await lib.attachment(a.id) == a)
    #expect(try await lib.attachmentFileURL(a.id)?.lastPathComponent == a.sha256)
    #expect(try await lib.attachmentFileURL(a.id)?.deletingLastPathComponent().lastPathComponent == "ba")
}

@Test func mimeFromExtension() async throws {
    let lib = try TestLibrary.open()
    #expect(try await lib.addAttachment(data: Data([1]), filename: "receipt.pdf").mime == "application/pdf")
    #expect(try await lib.addAttachment(data: Data([1]), filename: "x.unknownext").mime == "application/octet-stream")
    #expect(try await lib.addAttachment(data: Data([1]), filename: "noext").mime == "application/octet-stream")
    #expect(try await lib.addAttachment(data: Data([1]), filename: "x.png", mime: "image/x-custom").mime == "image/x-custom")
}

@Test func addFromFileUsesItsName() async throws {
    let lib = try TestLibrary.open()
    let src = TestLibrary.directory().appending(path: "Floor plan.png")
    try Data([9, 9]).write(to: src)
    let a = try await lib.addAttachment(contentsOf: src)
    #expect(a.filename == "Floor plan.png" && a.mime == "image/png" && a.size == 2)
}

@Test func noTempFilesLeft() async throws {
    let lib = try TestLibrary.open()
    _ = try await lib.addAttachment(data: Data("x".utf8), filename: "x")
    _ = try await lib.addAttachment(data: Data("x".utf8), filename: "x")
    let top = try FileManager.default.contentsOfDirectory(atPath: lib.directory.appending(path: "attachments").path)
    #expect(top.count == 1 && top[0].count == 2)
}

@Test func unknownAttachmentIsNil() async throws {
    let lib = try TestLibrary.open()
    #expect(try await lib.attachment(ULID.generate(at: 1)) == nil)
    #expect(try await lib.attachmentFileURL(ULID.generate(at: 1)) == nil)
}
