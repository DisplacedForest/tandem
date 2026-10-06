import Foundation
import Darwin
import CSQLite

final class Ledger: @unchecked Sendable {
    private var database: OpaquePointer?
    private var lockFD: Int32 = -1
    private let mutex = NSLock()
    let root: URL
    init(root: URL) throws {
        let fm = FileManager.default
        self.root = root.standardizedFileURL
        do {
        try require(self.root.path == root.standardizedFileURL.resolvingSymlinksInPath().path, .storage)
        let live = fm.homeDirectoryForCurrentUser.appendingPathComponent(".vera").resolvingSymlinksInPath().path
        try require(self.root.path != "/" && self.root.path != live && !self.root.path.hasPrefix(live + "/") && !live.hasPrefix(self.root.path + "/"), .storage)
        try fm.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = open(self.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        try require(directory >= 0, .storage)
        defer { close(directory) }
        var info = stat()
        try require(fstat(directory, &info) == 0 && info.st_uid == getuid() && (info.st_mode & 0o077) == 0, .storage)
        for name in ["spend.sqlite-wal", "spend.sqlite-shm", "spend.sqlite-journal"] {
            var sidecar = stat()
            if fstatat(directory, name, &sidecar, AT_SYMLINK_NOFOLLOW) == 0 {
                try require((sidecar.st_mode & S_IFMT) == S_IFREG && sidecar.st_uid == getuid() && sidecar.st_nlink == 1 && (sidecar.st_mode & 0o077) == 0, .storage)
            } else { try require(errno == ENOENT, .storage) }
        }
        lockFD = openat(directory, "broker.lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        try Self.secure(lockFD)
        try require(flock(lockFD, LOCK_EX | LOCK_NB) == 0, .storage)
        let file = openat(directory, "spend.sqlite", O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        defer { if file >= 0 { close(file) } }
        try Self.secure(file)
        guard let canonical = realpath(self.root.path, nil) else { throw Failure.storage }
        defer { free(canonical) }
        let path = String(cString: canonical) + "/spend.sqlite"
        try require(sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | 0x01000000, nil) == SQLITE_OK, .storage)
        let version = try rows("PRAGMA user_version").first?["user_version"] ?? "0"
        try require(["0", "2"].contains(version), .storage)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
        try execute("PRAGMA busy_timeout=2000")
        try execute("CREATE TABLE IF NOT EXISTS experiments(id TEXT PRIMARY KEY,digest TEXT NOT NULL,baseline INTEGER NOT NULL,budget INTEGER NOT NULL,max_requests INTEGER NOT NULL,transport TEXT NOT NULL,credential_attempted INTEGER NOT NULL DEFAULT 0)")
        try execute("CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY,experiment TEXT NOT NULL,task_id TEXT NOT NULL,role TEXT NOT NULL,calls INTEGER NOT NULL DEFAULT 0,tools INTEGER NOT NULL DEFAULT 0,mode TEXT NOT NULL DEFAULT '')")
        try execute("CREATE TABLE IF NOT EXISTS requests(id TEXT PRIMARY KEY,experiment TEXT NOT NULL,session TEXT NOT NULL,digest TEXT NOT NULL,status TEXT NOT NULL,reserved INTEGER NOT NULL,charged INTEGER,usage_input INTEGER,usage_output INTEGER,created REAL NOT NULL,account_usage INTEGER NOT NULL,finished REAL,model TEXT NOT NULL)")
        try execute("PRAGMA user_version=2")
        try validateRows()
        try execute("UPDATE requests SET status='uncertain',finished=? WHERE status='reserved'", [String(Date().timeIntervalSince1970)])
        } catch {
            if let database { sqlite3_close(database); self.database = nil }
            if lockFD >= 0 { close(lockFD); lockFD = -1 }
            throw error
        }
    }
    deinit { if let database { sqlite3_close(database) }; if lockFD >= 0 { close(lockFD) } }
    private static func secure(_ fd: Int32) throws {
        var info = stat()
        try require(fd >= 0 && fstat(fd, &info) == 0 && info.st_uid == getuid() && (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1 && (info.st_mode & 0o077) == 0, .storage)
    }
    private func integer(_ row: [String: String], _ key: String) throws -> Int64 {
        guard let text = row[key], let value = Int64(text), value >= 0, value <= 1_000_000_000_000 else { throw Failure.storage }
        return value
    }
    private func statement(_ sql: String, _ values: [String]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        try require(sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, .storage)
        guard let statement else { throw Failure.storage }
        for (index, value) in values.enumerated() {
            let result = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            if result != SQLITE_OK { sqlite3_finalize(statement); throw Failure.storage }
        }
        return statement
    }
    private func execute(_ sql: String, _ values: [String] = []) throws {
        let command = try statement(sql, values); defer { sqlite3_finalize(command) }
        var result = sqlite3_step(command)
        while result == SQLITE_ROW { result = sqlite3_step(command) }
        try require(result == SQLITE_DONE, .storage)
    }
    private func rows(_ sql: String, _ values: [String] = []) throws -> [[String: String]] {
        let command = try statement(sql, values); defer { sqlite3_finalize(command) }
        var result: [[String: String]] = []
        while true {
            let state = sqlite3_step(command)
            if state == SQLITE_DONE { return result }
            try require(state == SQLITE_ROW, .storage)
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(command) {
                if let key = sqlite3_column_name(command, index), let value = sqlite3_column_text(command, index) {
                    row[String(cString: key)] = String(cString: value)
                }
            }
            result.append(row)
        }
    }
    private func validateRows() throws {
        let invalid = try rows("SELECT id FROM experiments WHERE typeof(baseline)!='integer' OR baseline<0 OR baseline>200000000000 OR typeof(budget)!='integer' OR budget<=0 OR budget>1000000000 OR typeof(max_requests)!='integer' OR max_requests<1 OR max_requests>12 OR transport NOT IN ('mock','live') OR typeof(credential_attempted)!='integer' OR credential_attempted NOT IN (0,1) LIMIT 1")
        try require(invalid.isEmpty, .storage)
        try require(try rows("SELECT id FROM sessions WHERE experiment NOT IN (SELECT id FROM experiments) OR mode NOT IN ('','assistant','focused') OR role NOT IN ('foreground','worker') OR typeof(calls)!='integer' OR calls<0 OR calls>4 OR typeof(tools)!='integer' OR tools<0 OR tools>8 LIMIT 1").isEmpty, .storage)
        try require(try rows("SELECT requests.id FROM requests LEFT JOIN sessions ON requests.session=sessions.id WHERE sessions.id IS NULL OR requests.experiment!=sessions.experiment OR model!='qwen/qwen3.8-flash' OR typeof(account_usage)!='integer' OR account_usage<0 OR account_usage>200000000000 OR status NOT IN ('reserved','completed','uncertain') OR typeof(reserved)!='integer' OR reserved<0 OR reserved>1000000000 OR (charged IS NOT NULL AND (typeof(charged)!='integer' OR charged<0 OR charged>1000000000000)) OR (status='reserved' AND charged IS NOT NULL) OR (status='completed' AND (charged IS NULL OR charged>reserved OR usage_input IS NULL OR usage_output IS NULL)) OR (usage_input IS NOT NULL AND (typeof(usage_input)!='integer' OR usage_input<0 OR usage_input>16384)) OR (usage_output IS NOT NULL AND (typeof(usage_output)!='integer' OR usage_output<0 OR usage_output>256)) LIMIT 1").isEmpty, .storage)
    }
    func bind(_ permit: Permit) throws {
        mutex.lock(); defer { mutex.unlock() }
        try validateRows()
        try execute("BEGIN IMMEDIATE")
        do {
            try require(try rows("SELECT id FROM experiments WHERE transport!=? LIMIT 1", [permit.transport]).isEmpty, .unauthorized)
            if let prior = try rows("SELECT digest FROM experiments WHERE id=?", [permit.experiment]).first {
                try require(prior["digest"] == permit.digest, .unauthorized)
            } else {
                try execute("INSERT INTO experiments(id,digest,baseline,budget,max_requests,transport) VALUES(?,?,?,?,?,?)", [permit.experiment, permit.digest, String(permit.baseline), String(permit.budget), String(permit.maxRequests), permit.transport])
                for item in permit.sessions.values {
                    try execute("INSERT INTO sessions(id,experiment,task_id,role) VALUES(?,?,?,?)", [item.id, permit.experiment, item.taskID, item.role])
                }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func claimCredential(_ permit: Permit) throws {
        mutex.lock(); defer { mutex.unlock() }
        try validateRows()
        try execute("UPDATE experiments SET credential_attempted=1 WHERE id=? AND digest=? AND credential_attempted=0", [permit.experiment, permit.digest])
        try require(sqlite3_changes(database) == 1, .credentialUnavailable)
    }
    func check(_ request: Completion) throws {
        mutex.lock(); defer { mutex.unlock() }
        try validateRows()
        if let prior = try rows("SELECT digest,status FROM requests WHERE id=?", [request.id]).first {
            throw prior["digest"] == request.digest ? Failure.duplicate : Failure.unauthorized
        }
        try require(try rows("SELECT id FROM requests WHERE status='uncertain' LIMIT 1").isEmpty, .uncertain)
        try execute("UPDATE sessions SET task_id=?,mode=? WHERE id=? AND role=? AND (task_id='' OR task_id=?) AND (mode='' OR mode=?)", [request.session.taskID, request.mode, request.session.id, request.session.role, request.session.taskID, request.mode])
        let bound = try rows("SELECT task_id,role,mode FROM sessions WHERE id=?", [request.session.id]).first
        try require(bound?["task_id"] == request.session.taskID && bound?["role"] == request.session.role && bound?["mode"] == request.mode, .unauthorized)
    }
    func reserve(_ request: Completion, permit: Permit, amount: Int64, keyUsage: Int64) throws {
        mutex.lock(); defer { mutex.unlock() }
        try validateRows()
        try execute("BEGIN IMMEDIATE")
        do {
            try require(amount >= 0 && amount <= permit.budget && keyUsage >= 0 && keyUsage <= 200_000_000_000, .budget)
            try require(try rows("SELECT id FROM requests WHERE id=?", [request.id]).isEmpty, .duplicate)
            try require(try rows("SELECT id FROM requests WHERE status='uncertain' LIMIT 1").isEmpty, .uncertain)
            let own = try rows("SELECT COALESCE(SUM(COALESCE(charged,reserved)),0) AS amount,COUNT(*) AS count FROM requests WHERE experiment=?", [permit.experiment])[0]
            try require(try integer(own, "count") < permit.maxRequests && integer(own, "amount") + amount <= permit.budget, .budget)
            let total = try rows("SELECT COALESCE(SUM(COALESCE(charged,reserved)),0) AS amount FROM requests")[0]
            let baseline = try rows("SELECT COALESCE(MAX(baseline),0) AS amount FROM experiments")[0]
            try require(try max(keyUsage, integer(baseline, "amount")) + integer(total, "amount") + amount <= 200_000_000_000, .budget)
            let current = try rows("SELECT calls,tools FROM sessions WHERE id=? AND experiment=?", [request.session.id, permit.experiment])
            try require(try current.count == 1 && integer(current[0], "calls") < 4 && integer(current[0], "tools") <= 8, .budget)
            try require(try rows("SELECT requests.id FROM requests JOIN sessions ON sessions.id=requests.session WHERE requests.status='reserved' AND sessions.role=?", [request.session.role]).isEmpty, .unavailable)
            try execute("INSERT INTO requests VALUES(?,?,?,?,'reserved',?,NULL,NULL,NULL,?,?,NULL,?)", [request.id, permit.experiment, request.session.id, request.digest, String(amount), String(Date().timeIntervalSince1970), String(keyUsage), modelID])
            try execute("UPDATE sessions SET calls=calls+1 WHERE id=?", [request.session.id])
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func settle(_ request: Completion, charged: Int64, input: Int, output: Int, tools: Int) throws {
        mutex.lock(); defer { mutex.unlock() }
        try validateRows()
        try execute("BEGIN IMMEDIATE")
        do {
            let row = try rows("SELECT reserved,status FROM requests WHERE id=? AND digest=?", [request.id, request.digest]).first
            guard let row, row["status"] == "reserved" else { throw Failure.storage }
            let reserved = try integer(row, "reserved")
            guard let session = try rows("SELECT tools FROM sessions WHERE id=?", [request.session.id]).first else { throw Failure.storage }
            try require(charged >= 0 && input >= 0 && output >= 0 && tools >= 0 && tools <= 8, .providerResponse)
            let accepted = try charged <= reserved && input <= 16384 && output <= 256 && integer(session, "tools") + Int64(tools) <= 8
            try execute("UPDATE requests SET status=?,charged=?,usage_input=?,usage_output=?,finished=? WHERE id=?", [accepted ? "completed" : "uncertain", String(charged), String(input), String(output), String(Date().timeIntervalSince1970), request.id])
            try execute("UPDATE sessions SET tools=tools+? WHERE id=?", [String(tools), request.session.id])
            try execute("COMMIT")
            try require(accepted, .budget)
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func uncertain(_ id: String) {
        mutex.lock(); defer { mutex.unlock() }
        try? execute("UPDATE requests SET status='uncertain',finished=? WHERE id=? AND status='reserved'", [String(Date().timeIntervalSince1970), id])
    }
    func snapshot() throws -> [[String: String]] {
        mutex.lock(); defer { mutex.unlock() }
        try validateRows()
        return try rows("SELECT * FROM requests ORDER BY created")
    }
}
