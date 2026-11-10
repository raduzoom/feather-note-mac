import CryptoKit
import Foundation

/// A streaming pre-pass over an ENEX file: every `<data>` section outside CDATA is base64-decoded in chunks
/// straight to `scratch/rN` (MD5 computed on the way) and replaced by the token `rN` in a skeleton copy of the
/// file. XMLParser then reads only the small skeleton, so a large attachment never sits in memory.
struct ResourceExtractor {
    struct Resource { var file: URL; var md5: String }

    let skeleton: URL
    let resources: [String: Resource]   // by token

    init(enex: URL, scratch: URL) throws {
        let input = try FileHandle(forReadingFrom: enex)
        defer { try? input.close() }
        let skeletonURL = scratch.appending(path: "skeleton.enex")
        FileManager.default.createFile(atPath: skeletonURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: skeletonURL)
        defer { try? output.close() }

        var found: [String: Resource] = [:]
        var buffer: [UInt8] = []
        var outBuffer: [UInt8] = []
        let open = Array("<data".utf8), close = Array("</data>".utf8)
        let cdataOpen = Array("<![CDATA[".utf8), cdataClose = Array("]]>".utf8)
        enum State { case xml, cdata, dataTag, data }
        var state = State.xml
        var count = 0
        var dataFile: FileHandle?
        var md5 = Insecure.MD5()
        var base64: [UInt8] = []

        func flushOut() throws {
            if outBuffer.count > 0 { try output.write(contentsOf: outBuffer); outBuffer.removeAll(keepingCapacity: true) }
        }
        func decode(final: Bool) throws {
            let usable = final ? base64.count : base64.count / 4 * 4
            guard usable > 0 else { return }
            var chunk = Array(base64[0..<usable])
            base64.removeFirst(usable)
            if final, chunk.count % 4 != 0 { chunk += Array(repeating: UInt8(ascii: "="), count: 4 - chunk.count % 4) }
            if let data = Data(base64Encoded: Data(chunk)) {
                md5.update(data: data)
                try dataFile?.write(contentsOf: data)
            }
        }
        func starts(_ needle: [UInt8], at i: Int) -> Bool? {
            if i + needle.count > buffer.count { return nil }   // need more bytes
            for k in 0..<needle.count where buffer[i + k] != needle[k] { return false }
            return true
        }

        var eof = false
        while true {
            // each chunk in its own pool: FileHandle's data is autoreleased, and one long loop would keep it all
            try autoreleasepool {
                if !eof, let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { buffer += chunk } else { eof = true }
            }
            var i = 0
            scan: while i < buffer.count {
                switch state {
                case .xml:
                    if buffer[i] == UInt8(ascii: "<") {
                        // a match that might continue past this chunk waits for more bytes
                        let c = starts(cdataOpen, at: i)
                        if c == nil, !eof { break scan }
                        if c == true { outBuffer += cdataOpen; i += cdataOpen.count; state = .cdata; continue }
                        let d = starts(open, at: i)
                        if d == nil, !eof { break scan }
                        if d == true {
                            if i + open.count >= buffer.count, !eof { break scan }
                            let next = i + open.count < buffer.count ? buffer[i + open.count] : 0
                            if [UInt8(ascii: ">"), UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r")].contains(next) {
                                outBuffer += open; i += open.count; state = .dataTag; continue
                            }
                        }
                    }
                    outBuffer.append(buffer[i]); i += 1
                case .cdata:
                    if buffer[i] == UInt8(ascii: "]") {
                        if let c = starts(cdataClose, at: i) {
                            if c { outBuffer += cdataClose; i += cdataClose.count; state = .xml; continue }
                        } else if !eof { break scan }
                    }
                    outBuffer.append(buffer[i]); i += 1
                case .dataTag:
                    outBuffer.append(buffer[i])
                    if buffer[i] == UInt8(ascii: ">") {
                        count += 1
                        let token = "r\(count)"
                        let file = scratch.appending(path: token)
                        FileManager.default.createFile(atPath: file.path, contents: nil)
                        dataFile = try FileHandle(forWritingTo: file)
                        md5 = Insecure.MD5()
                        base64.removeAll(keepingCapacity: true)
                        outBuffer += Array(token.utf8)
                        found[token] = Resource(file: file, md5: "")
                        state = .data
                    }
                    i += 1
                case .data:
                    if buffer[i] == UInt8(ascii: "<") {
                        guard let c = starts(close, at: i) else { if eof { i += 1; continue }; break scan }
                        if c {
                            try decode(final: true)
                            try dataFile?.close()
                            dataFile = nil
                            let token = "r\(count)"
                            found[token]?.md5 = md5.finalize().map { String(format: "%02x", $0) }.joined()
                            outBuffer += close; i += close.count; state = .xml; continue
                        }
                    }
                    let b = buffer[i]
                    if b > 0x20 { base64.append(b) }   // skip whitespace
                    if base64.count >= 1 << 16 { try decode(final: false) }
                    i += 1
                }
            }
            buffer.removeFirst(i)
            try flushOut()
            if eof { break }
        }
        try? dataFile?.close()
        skeleton = skeletonURL
        resources = found
    }
}
