import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum ExifMetadataValue {
    case missing
    case date(Date)
}

struct ThumbnailMetadata {
    let width: Int
    let height: Int
    let aspect: Float
}

final class MetadataStore {
    private let db: OpaquePointer
    private let queue = DispatchQueue(label: "pixe.metadata.sqlite", qos: .utility)

    init?(directory: String) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory) {
            do {
                try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
            } catch {
                fputs("pixe: failed to create metadata directory: \(error.localizedDescription)\n", stderr)
                return nil
            }
        }

        let dbPath = (directory as NSString).appendingPathComponent("metadata.sqlite3")
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbPath, &handle, flags, nil) == SQLITE_OK, let opened = handle else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            fputs("pixe: failed to open metadata db: \(message)\n", stderr)
            if let handle { sqlite3_close(handle) }
            return nil
        }

        self.db = opened

        sqlite3_busy_timeout(opened, 3000)
        _ = exec("PRAGMA journal_mode=WAL;")
        _ = exec("PRAGMA synchronous=NORMAL;")
        _ = exec("PRAGMA temp_store=MEMORY;")

        guard migrateSchema() else {
            sqlite3_close(opened)
            return nil
        }
    }

    deinit {
        queue.sync {
            sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
            sqlite3_close(db)
        }
    }

    func flush() {
        _ = queue.sync {
            sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil)
        }
    }

    func thumbnail(forKey key: String) -> ThumbnailMetadata? {
        queue.sync {
            let sql = "SELECT width, height, aspect FROM thumb_meta WHERE cache_key = ?1 LIMIT 1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                return nil
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, key, -1, sqliteTransient)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

            let width = Int(sqlite3_column_int(stmt, 0))
            let height = Int(sqlite3_column_int(stmt, 1))
            let aspect = Float(sqlite3_column_double(stmt, 2))
            return ThumbnailMetadata(width: width, height: height, aspect: aspect)
        }
    }

    func upsertThumbnail(
        key: String,
        sourcePath: String,
        sourceMtime: Double,
        width: Int,
        height: Int,
        aspect: Float
    ) {
        queue.sync {
            let sql = """
            INSERT INTO thumb_meta(cache_key, source_path, source_mtime, width, height, aspect, updated_at)
            VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
            ON CONFLICT(cache_key) DO UPDATE SET
                source_path = excluded.source_path,
                source_mtime = excluded.source_mtime,
                width = excluded.width,
                height = excluded.height,
                aspect = excluded.aspect,
                updated_at = excluded.updated_at;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                return
            }
            defer { sqlite3_finalize(stmt) }

            let now = Date().timeIntervalSince1970
            sqlite3_bind_text(stmt, 1, key, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 2, sourcePath, -1, sqliteTransient)
            sqlite3_bind_double(stmt, 3, sourceMtime)
            sqlite3_bind_int64(stmt, 4, Int64(width))
            sqlite3_bind_int64(stmt, 5, Int64(height))
            sqlite3_bind_double(stmt, 6, Double(aspect))
            sqlite3_bind_double(stmt, 7, now)
            _ = sqlite3_step(stmt)
        }
    }

    func removeThumbnail(forKey key: String) {
        queue.sync {
            let sql = "DELETE FROM thumb_meta WHERE cache_key = ?1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                return
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, key, -1, sqliteTransient)
            _ = sqlite3_step(stmt)
        }
    }

    func allThumbnailKeys() -> Set<String> {
        queue.sync {
            let sql = "SELECT cache_key FROM thumb_meta;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                return []
            }
            defer { sqlite3_finalize(stmt) }

            var keys: Set<String> = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let cstr = sqlite3_column_text(stmt, 0) else { continue }
                keys.insert(String(cString: cstr))
            }
            return keys
        }
    }

    func cachedExif(path: String, mtime: Double, fileSize: Int64) -> ExifMetadataValue? {
        queue.sync {
            let sql = """
            SELECT mtime, file_size, exif_capture_ts, exif_checked
            FROM image_meta
            WHERE path = ?1
            LIMIT 1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                return nil
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, path, -1, sqliteTransient)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

            let cachedMtime = sqlite3_column_double(stmt, 0)
            let cachedSize = sqlite3_column_int64(stmt, 1)
            let checked = sqlite3_column_int(stmt, 3) != 0

            guard checked,
                  abs(cachedMtime - mtime) < 0.000_001,
                  cachedSize == fileSize else {
                return nil
            }

            if sqlite3_column_type(stmt, 2) == SQLITE_NULL {
                return .missing
            }
            let ts = sqlite3_column_double(stmt, 2)
            return .date(Date(timeIntervalSince1970: ts))
        }
    }

    func cachedExifWithoutSignature(path: String) -> ExifMetadataValue? {
        queue.sync {
            let sql = """
            SELECT exif_capture_ts, exif_checked
            FROM image_meta
            WHERE path = ?1
            LIMIT 1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                return nil
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, path, -1, sqliteTransient)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

            let checked = sqlite3_column_int(stmt, 1) != 0
            guard checked else { return nil }
            if sqlite3_column_type(stmt, 0) == SQLITE_NULL {
                return .missing
            }
            let ts = sqlite3_column_double(stmt, 0)
            return .date(Date(timeIntervalSince1970: ts))
        }
    }

    func upsertExif(path: String, mtime: Double, fileSize: Int64, captureDate: Date?) {
        queue.sync {
            let sql = """
            INSERT INTO image_meta(path, mtime, file_size, exif_capture_ts, exif_checked, updated_at)
            VALUES(?1, ?2, ?3, ?4, 1, ?5)
            ON CONFLICT(path) DO UPDATE SET
                mtime = excluded.mtime,
                file_size = excluded.file_size,
                exif_capture_ts = excluded.exif_capture_ts,
                exif_checked = 1,
                updated_at = excluded.updated_at;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                return
            }
            defer { sqlite3_finalize(stmt) }

            let now = Date().timeIntervalSince1970
            sqlite3_bind_text(stmt, 1, path, -1, sqliteTransient)
            sqlite3_bind_double(stmt, 2, mtime)
            sqlite3_bind_int64(stmt, 3, fileSize)
            if let captureDate {
                sqlite3_bind_double(stmt, 4, captureDate.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_double(stmt, 5, now)
            _ = sqlite3_step(stmt)
        }
    }

    func cachedDirectoryEntries(dirPath: String, filter: ExtensionFilter) -> [String] {
        queue.sync {
            let sql = """
            SELECT path
            FROM directory_entries
            WHERE dir_path = ?1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                return []
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, dirPath, -1, sqliteTransient)
            var paths: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let cstr = sqlite3_column_text(stmt, 0) else { continue }
                let path = String(cString: cstr)
                guard filter.accepts(path) else { continue }
                paths.append(path)
            }
            return paths
        }
    }

    func replaceDirectoryEntries(dirPath: String, paths: [String]) {
        queue.sync {
            guard exec("BEGIN IMMEDIATE TRANSACTION;") else { return }

            var deleteStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM directory_entries WHERE dir_path = ?1;", -1, &deleteStmt, nil) == SQLITE_OK,
               let deleteStmt {
                sqlite3_bind_text(deleteStmt, 1, dirPath, -1, sqliteTransient)
                _ = sqlite3_step(deleteStmt)
                sqlite3_finalize(deleteStmt)
            }

            let insertSQL = """
            INSERT OR IGNORE INTO directory_entries(dir_path, path, updated_at)
            VALUES(?1, ?2, ?3);
            """
            var insertStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK,
               let insertStmt {
                let now = Date().timeIntervalSince1970
                for path in paths {
                    sqlite3_reset(insertStmt)
                    sqlite3_clear_bindings(insertStmt)
                    sqlite3_bind_text(insertStmt, 1, dirPath, -1, sqliteTransient)
                    sqlite3_bind_text(insertStmt, 2, path, -1, sqliteTransient)
                    sqlite3_bind_double(insertStmt, 3, now)
                    _ = sqlite3_step(insertStmt)
                }
                sqlite3_finalize(insertStmt)
            }

            _ = exec("COMMIT;")
        }
    }

    private func migrateSchema() -> Bool {
        exec(
            """
            CREATE TABLE IF NOT EXISTS thumb_meta (
                cache_key TEXT PRIMARY KEY,
                source_path TEXT NOT NULL,
                source_mtime REAL NOT NULL,
                width INTEGER NOT NULL,
                height INTEGER NOT NULL,
                aspect REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """
        ) &&
        exec("CREATE INDEX IF NOT EXISTS idx_thumb_source_path ON thumb_meta(source_path);") &&
        exec(
            """
            CREATE TABLE IF NOT EXISTS image_meta (
                path TEXT PRIMARY KEY,
                mtime REAL NOT NULL,
                file_size INTEGER NOT NULL,
                exif_capture_ts REAL,
                exif_checked INTEGER NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL
            );
            """
        ) &&
        exec(
            """
            CREATE TABLE IF NOT EXISTS directory_entries (
                dir_path TEXT NOT NULL,
                path TEXT NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY(dir_path, path)
            );
            """
        ) &&
        exec("CREATE INDEX IF NOT EXISTS idx_directory_entries_path ON directory_entries(path);") &&
        exec("CREATE INDEX IF NOT EXISTS idx_directory_entries_dir ON directory_entries(dir_path);") &&
        exec("CREATE INDEX IF NOT EXISTS idx_image_exif_capture ON image_meta(exif_capture_ts);")
    }

    private func exec(_ sql: String) -> Bool {
        var errorPtr: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorPtr)
        if result != SQLITE_OK {
            if let errorPtr {
                let message = String(cString: errorPtr)
                fputs("pixe: sqlite error: \(message)\n", stderr)
                sqlite3_free(errorPtr)
            }
            return false
        }
        return true
    }
}
