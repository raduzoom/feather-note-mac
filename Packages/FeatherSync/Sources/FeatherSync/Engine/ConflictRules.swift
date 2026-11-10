import FeatherCore
import Foundation

/// What to do with a note that changed here and on the server (sync-protocol.md "Conflict resolution", Notes).
public enum NoteResolution: Equatable, Sendable {
    /// Take the server's version; nothing local is worth keeping (a local delete lost to an edit).
    case keepServer
    /// Title or body differ: take the server's, save the local one as a conflict copy.
    case copyLocal
    /// Only metadata differs: push this merge on top of the server's version.
    case mergeMeta(Note)
    /// The server deleted it while it was edited here: push the local version again (it comes back everywhere).
    case repushLocal
}

public enum NameResolution: Equatable, Sendable {
    /// The server's name wins; `lost` is the local name that lost, if it differed.
    case serverWins(lost: String?)
}

public enum ConflictRules {
    public static func resolveNote(local: Note, server: Note, localDeleted: Bool, serverDeleted: Bool) -> NoteResolution {
        if localDeleted { return .keepServer }
        if serverDeleted { return .repushLocal }
        if local.title != server.title || local.body != server.body { return .copyLocal }
        var merged = server
        merged.tagIDs = local.tagIDs.union(server.tagIDs)
        return .mergeMeta(merged)
    }

    /// `<title> (conflict, <device>, <d MMM HH:mm>)`, 24-hour, this Mac's time zone.
    public static func conflictTitle(_ title: String, device: String, at date: Date, calendar: Calendar = .current,
                                     timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = timeZone
        f.dateFormat = "d MMM HH:mm"
        return "\(title) (conflict, \(device), \(f.string(from: date)))"
    }

    public static func resolveName(localName: String, serverName: String) -> NameResolution {
        .serverWins(lost: localName == serverName ? nil : localName)
    }

    /// The server's parent, unless putting the notebook there would place it inside its own sub-notebook;
    /// then it goes to the top level (and the caller pushes that).
    public static func resolveParent(serverParent: ULID?, notebookID: ULID, parents: [ULID: ULID?]) -> ULID? {
        var current = serverParent
        var seen: Set<ULID> = []
        while let c = current {
            if c == notebookID { return nil }
            guard seen.insert(c).inserted else { return nil }
            current = parents[c] ?? nil
        }
        return serverParent
    }
}
