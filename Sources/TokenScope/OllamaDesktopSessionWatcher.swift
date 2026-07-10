import Foundation
import SQLite3

/// Read-only adapter for the Ollama Desktop conversation store. The database is
/// an implementation detail, so every query is guarded by schema inspection and
/// failures simply disable attribution; gateway token accounting keeps working.
final class OllamaDesktopSessionWatcher {
    private let store: UsageStore
    private let queue = DispatchQueue(label: "tokenscope.ollama-desktop", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastMessageId: Int64 = 0
    private var initialized = false
    private var knownTitles: [String: String] = [:]

    private let databaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Ollama/db.sqlite")

    init(store: UsageStore) { self.store = store }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 1)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    private func poll() {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return }
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else { return }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        guard schemaSupported(db) else {
            if !initialized { FileLog.log("Ollama Desktop session schema unsupported; attribution disabled") }
            initialized = true
            return
        }
        if !initialized {
            lastMessageId = scalarInt64(db, "SELECT COALESCE(MAX(id), 0) FROM messages")
            initialized = true
            FileLog.log("Ollama Desktop session watcher ready")
            return
        }

        let sql = """
        SELECT m.id, m.chat_id, c.title, m.content, m.model_name,
               strftime('%s', m.created_at)
        FROM messages m JOIN chats c ON c.id = m.chat_id
        WHERE m.id > ? AND m.role = 'user'
        ORDER BY m.id ASC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, lastMessageId)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            lastMessageId = max(lastMessageId, id)
            guard let chatId = text(stmt, 1), let content = text(stmt, 3), !content.isEmpty else { continue }
            let rawTitle = text(stmt, 2) ?? ""
            let title = rawTitle.isEmpty ? "Ollama Desktop chat" : rawTitle
            let model = text(stmt, 4)
            let seconds = sqlite3_column_double(stmt, 5)
            let timestamp = seconds > 0 ? Date(timeIntervalSince1970: seconds) : Date()
            store.registerDesktopMessage(
                fingerprint: OllamaRequestInspector.fingerprintText(content),
                chatId: chatId,
                title: title,
                model: model,
                timestamp: timestamp)
        }
        refreshRecentTitles(db)
    }

    private func refreshRecentTitles(_ db: OpaquePointer) {
        var stmt: OpaquePointer?
        let sql = "SELECT id, title FROM chats WHERE title <> '' ORDER BY created_at DESC LIMIT 20"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let id = text(stmt, 0), let title = text(stmt, 1), !title.isEmpty {
                if knownTitles[id] != title {
                    knownTitles[id] = title
                    store.setSessionName(id, title)
                }
            }
        }
    }

    private func schemaSupported(_ db: OpaquePointer) -> Bool {
        let tables = Set(rows(db, "SELECT name FROM sqlite_master WHERE type='table'", column: 0))
        guard tables.contains("chats"), tables.contains("messages") else { return false }
        let messageColumns = Set(rows(db, "PRAGMA table_info(messages)", column: 1))
        let chatColumns = Set(rows(db, "PRAGMA table_info(chats)", column: 1))
        return ["id", "chat_id", "role", "content", "model_name", "created_at"].allSatisfy(messageColumns.contains)
            && ["id", "title"].allSatisfy(chatColumns.contains)
    }

    private func rows(_ db: OpaquePointer, _ sql: String, column: Int32) -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var values: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let value = text(stmt, column) { values.append(value) }
        }
        return values
    }

    private func scalarInt64(_ db: OpaquePointer, _ sql: String) -> Int64 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0
    }

    private func text(_ stmt: OpaquePointer, _ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: raw)
    }
}
