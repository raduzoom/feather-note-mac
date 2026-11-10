import FeatherCore
import FeatherCrypto
import Foundation
import CryptoKit

/// sync-protocol.md "Client sync algorithm" for one library and account, plus the schedule it runs on.
public actor SyncEngine {
    let library: Library
    let account: AccountService
    let libraryID: String
    let deviceName: String
    let clock: @Sendable () -> Date

    public private(set) var status: SyncStatus = .idle(lastSynced: nil)
    private var statusContinuations: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]

    public init(library: Library, account: AccountService, libraryID: String, deviceName: String,
                clock: @escaping @Sendable () -> Date = Date.init) {
        self.library = library
        self.account = account
        self.libraryID = libraryID
        self.deviceName = deviceName
        self.clock = clock
    }

    // MARK: Status

    public func statusUpdates() -> AsyncStream<SyncStatus> {
        let (stream, continuation) = AsyncStream<SyncStatus>.makeStream()
        let id = UUID()
        statusContinuations[id] = continuation
        continuation.yield(status)
        continuation.onTermination = { _ in Task { await self.dropContinuation(id) } }
        return stream
    }

    private func dropContinuation(_ id: UUID) { statusContinuations[id] = nil }

    private func set(_ s: SyncStatus) {
        status = s
        for c in statusContinuations.values { c.yield(s) }
    }

    // MARK: Test hooks

    /// Tests only: called with "afterPush" (item nil) and "beforeApply" (the pulled item's id), so a test can
    /// make a local edit at exactly that moment.
    private var testHook: (@Sendable (String, ULID?) async -> Void)?
    func setTestHook(_ hook: (@Sendable (String, ULID?) async -> Void)?) { testHook = hook }

    // MARK: One pass

    private var changedIDs: Set<ULID> = []

    /// Uploads blobs, pushes, pulls, resolves conflicts, and repeats once if resolving made new changes.
    /// Returns the ids of items pulled or changed by resolution in `changed`.
    private var passRunning = false

    /// One pass at a time: a second call waits for the first to finish (they would share state and push twice).
    public func syncOnce() async throws -> (report: SyncReport, changed: Set<ULID>) {
        while passRunning { try await Task.sleep(for: .milliseconds(20)) }
        passRunning = true
        defer { passRunning = false }
        return try await pass()
    }

    private func pass() async throws -> (report: SyncReport, changed: Set<ULID>) {
        guard let master = try await account.masterKey() else { throw APIError(status: 401, code: "unauthorized", retryAfter: nil) }
        let client = await account.client()
        var report = SyncReport()
        changedIDs = []
        for pass in 0..<2 {
            try Task.checkCancellation()
            _ = try await library.collectChanges()
            let dirty = try await library.dirtyItems()
            if pass == 1 && dirty.isEmpty { break }
            if !report.readOnly {
                do {
                    try await push(dirty, client: client, master: master, report: &report)
                    await testHook?("afterPush", nil)
                } catch let e as APIError where e.code == "read_only" {
                    report.readOnly = true
                }
            }
            try await pull(client: client, master: master, report: &report)
            _ = try await library.collectChanges()
            if try await library.dirtyItems().filter({ $0.metaVersion <= 1 }).isEmpty || report.readOnly { break }
        }
        return (report, changedIDs)
    }

    // MARK: Push

    private struct Pending { var item: SyncItem; var change: Change; var blobSHA: String? }

    private static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func push(_ dirty: [SyncItem], client: APIClient, master: Data, report: inout SyncReport) async throws {
        let order: [ItemType: Int] = [.attachment: 0, .notebook: 1, .tag: 1, .note: 2]
        let items = dirty.filter { $0.metaVersion <= 1 }.sorted { (order[$0.type]!, $0.dirtySeq ?? 0) < (order[$1.type]!, $1.dirtySeq ?? 0) }
        var pending: [Pending] = []
        for item in items {
            guard let dirtySeq = item.dirtySeq else { continue }
            if item.deleted {
                if item.serverVersion == 0 {   // never reached the server: nothing to tell it
                    try await library.markPushed(item.id, version: 0, blobSHA: nil, ifDirtySeq: dirtySeq)
                    continue
                }
                pending.append(Pending(item: item, change: Change(id: item.id.description, type: item.type.rawValue,
                                                                  baseVersion: item.serverVersion, deleted: true, meta: nil, blobSHA256: nil)))
                continue
            }
            guard let encoded = try await encode(item, master: master) else { continue }
            var blobSHA = item.blobSHA
            if let blob = encoded.blob, item.bodyDirty || item.blobSHA == nil {
                let sha = Self.sha(blob)
                do {
                    _ = try await client.putBlob(sha256: sha, data: blob)   // attachments come first: `items` is sorted
                } catch let e as APIError where e.code == "quota_exceeded" || e.code == "blob_too_large" {
                    report.rejected[item.id.description] = e.code   // stays dirty; the rest still syncs
                    if e.code == "quota_exceeded" { report.quotaFull = true }
                    continue
                }
                blobSHA = sha
            }
            let needsBlob = item.type == .note || item.type == .attachment
            pending.append(Pending(item: item, change: Change(id: item.id.description, type: item.type.rawValue, baseVersion: item.serverVersion,
                                                              deleted: false, meta: encoded.meta, blobSHA256: needsBlob ? blobSHA : nil),
                                   blobSHA: blobSHA))
        }
        let total = pending.count
        var done = 0
        if total > 0 { set(.syncing(done: 0, total: total)) }
        for batch in stride(from: 0, to: pending.count, by: 100).map({ Array(pending[$0..<min($0 + 100, pending.count)]) }) {
            let results = try await client.push(libraryID: libraryID, changes: batch.map(\.change))
            for (p, result) in zip(batch, results) {
                switch result {
                case let .accepted(_, version, _):
                    try await library.markPushed(p.item.id, version: version, blobSHA: p.blobSHA, ifDirtySeq: p.item.dirtySeq!)
                    report.pushed += 1
                case .conflict:
                    // left dirty: the pull returns the server's newer version in seq order, after anything it
                    // depends on (a tag, a notebook), and resolves it there
                    break
                case let .rejected(_, code):
                    report.rejected[p.item.id.description] = code
                    if code == "blob_missing" { try await library.markBodyDirty(p.item.id) }   // upload it again next pass
                    if code == "quota_exceeded" { report.quotaFull = true }
                }
            }
            done += batch.count
            set(.syncing(done: done, total: total))
        }
    }

    private func encode(_ item: SyncItem, master: Data) async throws -> EncodedItem? {
        switch item.type {
        case .note:
            guard let note = try await library.note(item.id) else { return nil }
            return try ItemCodec.encode(note: note, extraMeta: item.extraMeta, masterKey: master)
        case .notebook:
            guard let nb = try await library.notebooks().first(where: { $0.id == item.id }) else { return nil }
            return try ItemCodec.encode(notebook: nb, extraMeta: item.extraMeta, masterKey: master)
        case .tag:
            guard let tag = try await library.tags().first(where: { $0.id == item.id }) else { return nil }
            return try ItemCodec.encode(tag: tag, extraMeta: item.extraMeta, masterKey: master)
        case .attachment:
            guard let a = try await library.attachment(item.id), let url = try await library.attachmentFileURL(item.id) else { return nil }
            return try ItemCodec.encode(attachment: a, content: try Data(contentsOf: url), extraMeta: item.extraMeta, masterKey: master)
        }
    }

    // MARK: Pull

    /// Notes and notebooks whose notebook, tags or parent hadn't arrived yet: applied again after the pull.
    private var deferred: [RemoteItem] = []

    private func pull(client: APIClient, master: Data, report: inout SyncReport) async throws {
        var cursor = try await library.syncValue("pull_cursor")
        deferred = []
        while true {
            try Task.checkCancellation()
            let page = try await client.pull(libraryID: libraryID, cursor: cursor)
            for remote in page.items {
                if try await take(remote, client: client, master: master, report: &report) { report.pulled += 1 }
            }
            cursor = page.cursor
            try await library.setSyncValue("pull_cursor", cursor)
            if !page.hasMore { break }
        }
        // references arrive in seq order, so a note can come before a notebook renamed after it was filed there
        let again = deferred
        deferred = []
        for remote in again { _ = try await take(remote, client: client, master: master, report: &report, reapply: true) }
    }

    /// Applies one pulled item, or resolves it against a local change. A remote write is refused when this
    /// Mac changed the item after we looked (someone typed); then it is looked at again, up to three times.
    private func take(_ remote: RemoteItem, client: APIClient, master: Data, report: inout SyncReport, reapply: Bool = false) async throws -> Bool {
        guard let id = ULID(string: remote.id) else { return false }
        for _ in 0..<3 {
            _ = try await library.collectChanges()
            let local = try await library.syncItem(id)
            if let local, local.dirtySeq != nil {
                // our own push coming back, with a later edit on top: the next pass pushes that edit
                if remote.version <= local.serverVersion { return false }
                if try await resolve(local, remote: remote, client: client, master: master, report: &report) { return false }
            } else {
                if let local, local.serverVersion >= remote.version, !reapply { return false }   // our own push coming back
                await testHook?("beforeApply", id)
                if try await apply(remote, client: client, master: master, deferIncomplete: !reapply) { return true }
            }
        }
        return false
    }

    /// Decodes a remote item. `forceBlob` downloads the body even if its sha matches the one here (needed in
    /// conflicts, where the body here may be newer than that sha).
    private func decode(_ remote: RemoteItem, client: APIClient, master: Data, forceBlob: Bool) async throws -> DecodedItem? {
        guard let id = ULID(string: remote.id), let type = ItemType(rawValue: remote.type), let meta = remote.meta else { return nil }
        var blob: Data?
        let localSHA = try await library.syncItem(id)?.blobSHA
        if let ref = remote.blob, forceBlob || ref.sha256 != localSHA || type == .attachment {
            blob = try await client.getBlob(sha256: ref.sha256)
        }
        var decoded = try ItemCodec.decode(type: type, id: id, meta: meta, blob: blob, masterKey: master)
        if case let .note(n, extra, v) = decoded, blob == nil, remote.blob != nil {   // body unchanged and clean: keep it
            var note = n
            note.body = try await library.note(id)?.body ?? ""
            decoded = .note(note, extraMeta: extra, metaVersion: v)
        }
        return decoded
    }

    /// Applies a remote item to a clean local one. False when a local edit got in first.
    private func apply(_ remote: RemoteItem, client: APIClient, master: Data, deferIncomplete: Bool) async throws -> Bool {
        guard let id = ULID(string: remote.id), let type = ItemType(rawValue: remote.type) else { return true }
        if remote.deleted {
            let ok = try await library.applyRemoteDelete(id, type: type, version: remote.version)
            if ok { changedIDs.insert(id) }
            return ok
        }
        guard let decoded = try await decode(remote, client: client, master: master, forceBlob: false) else { return true }
        if deferIncomplete, try await !referencesResolve(decoded) { deferred.append(remote) }
        let ok = try await store(decoded, version: remote.version, blobSHA: remote.blob?.sha256, ifDirtySeq: nil)
        if ok { changedIDs.insert(id) }
        return ok
    }

    private func referencesResolve(_ decoded: DecodedItem) async throws -> Bool {
        switch decoded {
        case let .note(n, _, _): try await library.referencesResolve(notebookID: n.notebookID, tagIDs: n.tagIDs)
        case let .notebook(nb, _, _): try await library.referencesResolve(notebookID: nb.parentID, tagIDs: [])
        default: true
        }
    }

    private func store(_ decoded: DecodedItem, version: Int64, blobSHA: String?, ifDirtySeq: Int64?) async throws -> Bool {
        switch decoded {
        case let .note(n, extra, v):
            return try await library.applyRemote(note: n, version: version, blobSHA: blobSHA, extraMeta: extra, metaVersion: v, ifDirtySeq: ifDirtySeq)
        case let .notebook(nb, extra, v):
            var notebook = nb
            let parents = Dictionary(uniqueKeysWithValues: try await library.notebooks().map { ($0.id, $0.parentID) })
            let parent = ConflictRules.resolveParent(serverParent: nb.parentID, notebookID: nb.id, parents: parents)
            notebook.parentID = parent
            guard try await library.applyRemote(notebook: notebook, version: version, extraMeta: extra, metaVersion: v, ifDirtySeq: ifDirtySeq) else {
                return false
            }
            if parent != nb.parentID { try await library.moveNotebook(nb.id, toParent: nil) }   // pushed next pass
            return true
        case let .tag(tag, extra, v):
            return try await library.applyRemote(tag: tag, version: version, extraMeta: extra, metaVersion: v, ifDirtySeq: ifDirtySeq)
        case let .attachment(a, content, extra, v):
            return try await library.applyRemote(attachment: a, content: content, version: version, blobSHA: blobSHA, extraMeta: extra,
                                                 metaVersion: v, ifDirtySeq: ifDirtySeq)
        }
    }

    // MARK: Conflicts

    /// An item changed here (dirty) and on the server: the rules of sync-protocol.md "Conflict resolution".
    /// False when a newer local edit arrived meanwhile (the caller looks again).
    private func resolve(_ local: SyncItem, remote: RemoteItem, client: APIClient, master: Data, report: inout SyncReport) async throws -> Bool {
        let seq = local.dirtySeq
        changedIDs.insert(local.id)
        if remote.deleted {
            let editedNote = local.type == .note && !local.deleted ? try await library.note(local.id) : nil
            if editedNote != nil {
                try await library.rebase(local.id, version: remote.version)   // rule 3: it comes back everywhere
                return true
            }
            // a deletion wins over a local edit to a notebook, tag or attachment, and over a local delete
            return try await library.applyRemoteDelete(local.id, type: local.type, version: remote.version, ifDirtySeq: seq)
        }
        guard let decoded = try await decode(remote, client: client, master: master, forceBlob: true) else { return true }
        if local.metaVersion > 1 {   // read-only here: the server's version wins
            return try await store(decoded, version: remote.version, blobSHA: remote.blob?.sha256, ifDirtySeq: seq)
        }
        switch decoded {
        case let .note(server, extra, v):
            let mine = local.deleted ? nil : try await library.note(local.id)
            let apply = { try await self.library.applyRemote(note: server, version: remote.version, blobSHA: remote.blob?.sha256,
                                                             extraMeta: extra, metaVersion: v, ifDirtySeq: seq) }
            guard let mine else { return try await apply() }   // rule 4: a local delete loses to an edit
            switch ConflictRules.resolveNote(local: mine, server: server, localDeleted: false, serverDeleted: false) {
            case .copyLocal:
                guard try await apply() else { return false }
                let title = ConflictRules.conflictTitle(mine.title, device: deviceName, at: clock())
                let copy = try await library.createConflictCopy(of: mine, title: title)
                report.conflictCopies.append(copy.id.description)
                changedIDs.insert(copy.id)
                return true
            case .mergeMeta(let merged):
                guard try await apply() else { return false }
                if merged.tagIDs != server.tagIDs { try await library.setTags(merged.id, merged.tagIDs) }   // pushed next pass
                return true
            case .keepServer, .repushLocal:
                return try await apply()
            }
        case let .notebook(nb, _, _):
            return try await resolveName(local, serverName: nb.name, decoded, remote: remote, report: &report)
        case let .tag(tag, _, _):
            return try await resolveName(local, serverName: tag.name, decoded, remote: remote, report: &report)
        case .attachment:
            return try await store(decoded, version: remote.version, blobSHA: remote.blob?.sha256, ifDirtySeq: seq)
        }
    }

    /// Notebook and tag renames: the server's name wins; the losing local name is listed once.
    private func resolveName(_ local: SyncItem, serverName: String, _ decoded: DecodedItem, remote: RemoteItem,
                             report: inout SyncReport) async throws -> Bool {
        let localName: String? = local.type == .notebook
            ? try await library.notebooks().first { $0.id == local.id }?.name
            : try await library.tags().first { $0.id == local.id }?.name
        guard try await store(decoded, version: remote.version, blobSHA: nil, ifDirtySeq: local.dirtySeq) else { return false }
        if let localName, !local.deleted, case .serverWins(let lost?) = ConflictRules.resolveName(localName: localName, serverName: serverName) {
            try await library.recordSyncConflict(itemID: local.id, type: local.type, lostName: lost, device: deviceName)
            report.nameConflicts += 1
        }
        return true
    }

    // MARK: Schedule

    private var loop: Task<Void, Never>?
    private var wake: AsyncStream<Void>.Continuation?
    private var debounce: Task<Void, Never>?
    private var backoff = Backoff()
    private var lastSynced: Date?

    /// Syncs now, then every 5 minutes, 2 s after local changes, and on demand. `beforeSync` saves pending
    /// edits first; `onPulled` gets the ids that changed here.
    public func start(beforeSync: @escaping @Sendable () async -> Void, onPulled: @escaping @Sendable (Set<ULID>) async -> Void,
                      onSignedOut: @escaping @Sendable () async -> Void) {
        guard loop == nil else { return }
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wake = continuation
        continuation.yield()
        loop = Task {
            var iterator = stream.makeAsyncIterator()
            while !Task.isCancelled {
                let delay = await self.runOne(beforeSync: beforeSync, onPulled: onPulled, onSignedOut: onSignedOut)
                guard let delay else {   // signed out: a later start() begins a new schedule
                    await self.loopEnded()
                    return
                }
                // wait for a trigger or the timer, whichever comes first
                let timer = Task { try? await Task.sleep(for: delay); await self.trigger() }
                _ = await iterator.next()
                timer.cancel()
            }
        }
    }

    private func trigger() { wake?.yield() }

    private func loopEnded() {
        loop = nil
        wake?.finish()
        wake = nil
    }

    /// One scheduled pass; returns how long to wait for the next one, or nil to stop.
    private func runOne(beforeSync: @Sendable () async -> Void, onPulled: @Sendable (Set<ULID>) async -> Void,
                        onSignedOut: @Sendable () async -> Void) async -> Duration? {
        await beforeSync()
        do {
            let (report, changed) = try await syncOnce()
            backoff.reset()
            lastSynced = clock()
            if !changed.isEmpty { await onPulled(changed) }
            set(report.readOnly ? .readOnly : report.quotaFull ? .quotaFull : .idle(lastSynced: lastSynced))
            return .seconds(300)
        } catch is CancellationError {
            return nil
        } catch let e as APIError {
            switch e.status {
            case 401:
                set(.signedOut)
                await account.forget()
                await onSignedOut()
                return nil
            case 429:
                set(.error("Too many requests."))
                return .seconds(e.retryAfter ?? 60)
            case 0:
                set(.offline)
            default:
                set(.error("The server didn't respond."))
            }
            return backoff.next(random: Double.random(in: 0...1))
        } catch {
            set(.error("The server didn't respond."))
            return backoff.next(random: Double.random(in: 0...1))
        }
    }

    /// A local edit: sync 2 s after the last one.
    public func localChanged() {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { self.trigger() }
        }
    }

    public func syncNow() { trigger() }

    public func stop() {
        loop?.cancel()
        debounce?.cancel()
        wake?.finish()
        loop = nil
        wake = nil
    }
}
