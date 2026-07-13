import Foundation
import CSQLite
import Darwin

/// Observes only metadata from Ollama.app's local SQLite database. The desktop
/// client connects directly to the Ollama daemon and therefore bypasses the
/// TokenScope proxy. Its DB contains model and timestamps but no token counts;
/// prompts, responses, thinking, tool arguments, and attachments are never read.
final class OllamaDesktopWatcher {
    private let store: UsageStore
    private let dbURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Ollama/db.sqlite")
    private let queue = DispatchQueue(label: "tokenscope.ollama-desktop", qos: .utility)
    private var fileSources: [DispatchSourceFileSystemObject] = []
    private var db: OpaquePointer?
    private var lastSeenID: Int64 = 0
    private var pending: Set<Int64> = []
    private var scanGeneration = 0

    init(store: UsageStore) { self.store = store }

    deinit {
        fileSources.forEach { $0.cancel() }
        if let db { sqlite3_close(db) }
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.openIfAvailable()
            self.bootstrap()
            self.scan()
            self.armFileObservers()
        }
    }

    /// SQLite writes Ollama chat state through its WAL. Vnode notifications keep
    /// this collector idle between changes instead of adding another polling loop.
    private func armFileObservers() {
        fileSources.forEach { $0.cancel() }
        fileSources = []
        let directory = dbURL.deletingLastPathComponent()
        for url in [directory, dbURL, URL(fileURLWithPath: dbURL.path + "-wal")] {
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .delete, .rename, .revoke],
                queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.scheduleScan()
                // Directory changes include WAL creation/rotation. Re-arm after
                // them so a newly-created WAL descriptor is always observed.
                if url == directory {
                    self.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.armFileObservers()
                    }
                }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            fileSources.append(source)
        }
    }

    private func scheduleScan() {
        scanGeneration += 1
        let generation = scanGeneration
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.scanGeneration == generation else { return }
            self.scan()
        }
    }

    private func openIfAvailable() {
        guard db == nil, FileManager.default.fileExists(atPath: dbURL.path) else { return }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbURL.path, &handle, flags, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            return
        }
        db = handle
        sqlite3_busy_timeout(handle, 250)
        store.updateRuntimeHealth(.ollama) {
            $0.collectorRunning = true
            $0.coverage = "proxy tokens + desktop activity"
        }
        FileLog.log("Ollama Desktop metadata watcher active (message content is not read)")
    }

    private func bootstrap() {
        guard let db else { return }
        if let value = scalarInt64("SELECT COALESCE(MAX(id), 0) FROM messages", db: db) {
            lastSeenID = value
        }
        // The desktop DB is a durable metadata source, so restore the same live
        // retention window used by the rest of TokenScope. Stable row/chat keys
        // make this idempotent against the local event journal on every launch.
        let cutoff = store.eventsCutoff
        query("""
            SELECT id, chat_id, COALESCE(model_name, ''), created_at, updated_at, stream
            FROM messages WHERE role='assistant' AND stream = 0 ORDER BY id
            """, db: db) { statement in
            let row = self.row(statement)
            guard let completed = Self.parseDate(row.updatedAt), completed >= cutoff else { return }
            self.emit(row)
        }
        // Preserve an assistant response that was already streaming when
        // TokenScope launched, but do not replay older desktop history.
        query("SELECT id FROM messages WHERE role='assistant' AND stream != 0", db: db) { statement in
            self.pending.insert(sqlite3_column_int64(statement, 0))
        }
    }

    private func scan() {
        if db == nil {
            openIfAvailable()
            bootstrap()
        }
        guard let db else { return }

        query("""
            SELECT id, chat_id, COALESCE(model_name, ''), created_at, updated_at, stream
            FROM messages WHERE role='assistant' AND id > \(lastSeenID) ORDER BY id
            """, db: db) { statement in
            let row = self.row(statement)
            self.lastSeenID = max(self.lastSeenID, row.id)
            if row.streaming { self.pending.insert(row.id) }
            else { self.emit(row) }
        }

        var completedPending: [Int64] = []
        for id in pending {
            query("""
                SELECT id, chat_id, COALESCE(model_name, ''), created_at, updated_at, stream
                FROM messages WHERE id = \(id) AND role='assistant'
                """, db: db) { statement in
                let row = self.row(statement)
                if !row.streaming {
                    completedPending.append(id)
                    self.emit(row)
                }
            }
        }
        pending.subtract(completedPending)
    }

    private struct Row {
        let id: Int64
        let chatID: String
        let model: String
        let createdAt: String
        let updatedAt: String
        let streaming: Bool
    }

    private func row(_ statement: OpaquePointer) -> Row {
        Row(
            id: sqlite3_column_int64(statement, 0),
            chatID: text(statement, 1),
            model: text(statement, 2),
            createdAt: text(statement, 3),
            updatedAt: text(statement, 4),
            streaming: sqlite3_column_int(statement, 5) != 0)
    }

    private func emit(_ row: Row) {
        let started = Self.parseDate(row.createdAt) ?? Date()
        let completed = Self.parseDate(row.updatedAt) ?? started
        let observation = OllamaDesktopObservation(
            rowID: row.id, chatID: row.chatID, model: row.model,
            startedAt: started, completedAt: completed)
        store.addLocalEvent(observation.event, dedupKey: observation.dedupKey)
        store.updateRuntimeHealth(.ollama) {
            $0.lastEvent = completed
            $0.coverage = "proxy tokens + desktop activity"
        }
        // Per-event persistence is intentionally silent; startup replay can
        // contain hundreds of metadata rows and FileLog is lifecycle-only.
    }

    private func query(_ sql: String, db: OpaquePointer, row: (OpaquePointer) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
    }

    private func scalarInt64(_ sql: String, db: OpaquePointer) -> Int64? {
        var value: Int64?
        query(sql, db: db) { value = sqlite3_column_int64($0, 0) }
        return value
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let raw = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: raw)
    }

    private static func parseDate(_ value: String) -> Date? {
        // SQLite stores Ollama timestamps with a space separator and a variable
        // number of fractional digits. ISO8601 accepts them after normalization.
        let normalized = value.replacingOccurrences(of: " ", with: "T")
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: normalized) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: normalized)
    }
}
