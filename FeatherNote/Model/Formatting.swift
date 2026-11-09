import FeatherCore
import Foundation

/// Every user-visible string built from data. Pure functions: tests pass `now`, a calendar and a locale.
enum Formatting {
    static let day: TimeInterval = 86_400

    private static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }

    private static func style(_ calendar: Calendar, _ locale: Locale) -> Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    }

    private static func time(_ d: Date, _ calendar: Calendar, _ locale: Locale) -> String {
        d.formatted(style(calendar, locale).hour().minute())
    }

    /// "7 Nov", or "2 Nov 2025" outside the current year.
    private static func dayMonth(_ d: Date, now: Date, _ calendar: Calendar, _ locale: Locale) -> String {
        let sameYear = calendar.isDate(d, equalTo: now, toGranularity: .year)
        let s = style(calendar, locale).day().month(.abbreviated)
        return d.formatted(sameYear ? s : s.year())
    }

    /// "Today, 10:42", "Yesterday", "7 Nov", "2 Nov 2025".
    static func listDate(_ ms: Int64, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let d = date(ms)
        if calendar.isDate(d, inSameDayAs: now) { return "Today, \(time(d, calendar, locale))" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: y) { return "Yesterday" }
        return dayMonth(d, now: now, calendar, locale)
    }

    /// "Edited today at 10:42", "Edited yesterday at 09:00", "Edited 7 Nov".
    static func editedLine(_ ms: Int64, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let d = date(ms)
        if calendar.isDate(d, inSameDayAs: now) { return "Edited today at \(time(d, calendar, locale))" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: y) {
            return "Edited yesterday at \(time(d, calendar, locale))"
        }
        return "Edited \(dayMonth(d, now: now, calendar, locale))"
    }

    /// "Deleted 3 Nov · removed in 24 days".
    static func trashMeta(trashedAt: Int64, retentionDays: Int, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let d = date(trashedAt)
        let deleted: String
        if calendar.isDate(d, inSameDayAs: now) {
            deleted = "today"
        } else if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: y) {
            deleted = "yesterday"
        } else {
            deleted = dayMonth(d, now: now, calendar, locale)
        }
        let remaining = d.addingTimeInterval(TimeInterval(retentionDays) * day).timeIntervalSince(now)
        let removed: String
        if remaining <= 0 {
            removed = "removed today"
        } else {
            let days = Int((remaining / day).rounded(.up))
            removed = days == 1 ? "removed in 1 day" : "removed in \(days) days"
        }
        return "Deleted \(deleted) · \(removed)"
    }

    /// "Today, 10:42 · Electronics" (no notebook part at the root).
    static func noteMeta(summary: NoteSummary, notebookName: String?, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let when = listDate(summary.modified, now: now, calendar: calendar, locale: locale)
        return notebookName.map { "\(when) · \($0)" } ?? when
    }

    static func displayTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : title
    }

    struct Confirmation: Equatable {
        var title: String
        var message: String
        var button: String
    }

    private static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n) \(n == 1 ? singular : plural)"
    }

    static func deleteNotebookConfirmation(name: String, subNotebooks: Int, notes: Int) -> Confirmation {
        var parts: [String] = []
        if subNotebooks > 0 {
            parts.append("Its \(count(subNotebooks, "sub-notebook", "sub-notebooks")) \(subNotebooks == 1 ? "is" : "are") deleted too")
        }
        if notes > 0 {
            let move = "\(count(notes, "note", "notes")) \(notes == 1 ? "moves" : "move") to the Trash"
            parts.append(parts.isEmpty ? "Its \(move)" : "its \(move)")
        }
        let message = parts.isEmpty ? "It's empty." : parts.joined(separator: ", and ") + "."
        return Confirmation(title: "Delete “\(name)”?", message: message, button: "Delete Notebook")
    }

    static func emptyTrashConfirmation(count n: Int) -> Confirmation {
        Confirmation(title: "Empty the Trash?",
                     message: "\(count(n, "note", "notes")) will be deleted for good. This can't be undone.",
                     button: "Empty Trash")
    }

    static func deletePermanentlyConfirmation(title: String) -> Confirmation {
        Confirmation(title: "Delete “\(displayTitle(title))” permanently?", message: "This can't be undone.", button: "Delete Permanently")
    }

    /// "Groceries, pinned, Today, 08:15, Personal".
    static func rowAccessibilityLabel(summary: NoteSummary, notebookName: String?, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var parts = [displayTitle(summary.title)]
        if summary.pinned { parts.append("pinned") }
        parts.append(listDate(summary.modified, now: now, calendar: calendar, locale: locale))
        if let notebookName { parts.append(notebookName) }
        return parts.joined(separator: ", ")
    }
}
