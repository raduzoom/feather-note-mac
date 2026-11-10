import Foundation

/// An RFC 4180 CSV table: quoted fields may hold commas, doubled quotes and line breaks.
struct CSVTable: Equatable {
    var header: [String]
    var rows: [[String]]

    enum CSVError: LocalizedError {
        case unterminatedQuote
        var errorDescription: String? { "a database table in it can't be read: a quoted value is never closed." }
    }

    init(_ text: String) throws {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        chars.append("\n")
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," {
                record.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                record.append(field); field = ""
                if !(record.count == 1 && record[0].isEmpty) { records.append(record) }
                record = []
            } else {
                field.append(c)
            }
            i += 1
        }
        if inQuotes { throw CSVError.unterminatedQuote }
        header = records.first ?? []
        rows = Array(records.dropFirst())
    }
}
