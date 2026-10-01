//! Rust-owned SQLite persistence, separate from the transport-free ledger fold.
//! Native files use SQLite's crash-safe transactions. Browser callers serialize
//! an in-memory database and atomically save its bytes while holding a Web Lock.
//! The browser binding is single-threaded: its bridge API MUST be synchronous,
//! never dispatched to FRB's worker pool. No connection crosses a bridge call.

#[cfg(not(target_arch = "wasm32"))]
use std::{path::Path, time::Duration};

use rusqlite::{Connection, MAIN_DB, OptionalExtension, TransactionBehavior, params};

pub type Result<T> = std::result::Result<T, String>;
const APPLICATION_ID: i64 = 0x43415348; // CASH
const SCHEMA_VERSION: i64 = 1;

/// A document revision includes tombstones, so a deletion cannot revive legacy
/// state or allow a stale controller to replace a newer MLS sender ratchet.
#[derive(Debug, PartialEq, Eq)]
pub struct Document {
    pub revision: i64,
    pub value: Option<Vec<u8>>,
}

pub struct Database(Connection);

fn sql(error: rusqlite::Error) -> String {
    format!("local database: {error}")
}

impl Database {
    #[cfg(not(target_arch = "wasm32"))]
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let db = Connection::open(path).map_err(sql)?;
        db.busy_timeout(Duration::from_secs(5)).map_err(sql)?;
        // EXTRA also syncs the directory when deleting a rollback journal.
        // No unencrypted financial data is sent anywhere by this local store.
        db.execute_batch("PRAGMA journal_mode=DELETE; PRAGMA synchronous=EXTRA;")
            .map_err(sql)?;
        Self::initialize(db)
    }

    pub fn from_bytes(bytes: &[u8]) -> Result<Self> {
        let mut db = Connection::open_in_memory().map_err(sql)?;
        if !bytes.is_empty() {
            if bytes.len() < 512 || !bytes.starts_with(b"SQLite format 3\0") {
                return Err(
                    "saved local database is not a SQLite database; it was not replaced".into(),
                );
            }
            db.deserialize_read_exact(MAIN_DB, bytes, bytes.len(), false)
                .map_err(sql)?;
        }
        Self::initialize(db)
    }

    fn initialize(db: Connection) -> Result<Self> {
        db.execute_batch(
            "PRAGMA trusted_schema=OFF; PRAGMA foreign_keys=ON; PRAGMA temp_store=MEMORY;",
        )
        .map_err(sql)?;
        // Read identity/version and initialize under one writer lock. Separate
        // reads could otherwise observe different commits on concurrent opens.
        db.execute_batch("BEGIN IMMEDIATE;").map_err(sql)?;
        let application: i64 = db
            .query_row("PRAGMA application_id", [], |row| row.get(0))
            .map_err(sql)?;
        let version: i64 = db
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .map_err(sql)?;
        if application == 0 && version == 0 {
            let tables: i64 = db
                .query_row(
                    "SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'",
                    [],
                    |row| row.get(0),
                )
                .map_err(sql)?;
            if tables != 0 {
                return Err("unrecognized local database; it was not replaced".into());
            }
            db.execute_batch(
                "CREATE TABLE IF NOT EXISTS documents(name TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL CHECK(revision>0), value BLOB);
                 CREATE TABLE IF NOT EXISTS streams(name TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL CHECK(revision>0));
                 CREATE TABLE IF NOT EXISTS frames(stream TEXT NOT NULL REFERENCES streams(name), position INTEGER NOT NULL, value BLOB NOT NULL, PRIMARY KEY(stream,position));
                 CREATE TABLE IF NOT EXISTS recoveries(id INTEGER PRIMARY KEY, stream TEXT NOT NULL, original BLOB NOT NULL);
                 PRAGMA application_id=1128354632;
                 PRAGMA user_version=1;"
            ).map_err(sql)?;
        } else if application != APPLICATION_ID || version != SCHEMA_VERSION {
            return Err("unsupported local database version; it was not replaced".into());
        }
        let healthy: String = db
            .query_row("PRAGMA quick_check", [], |row| row.get(0))
            .map_err(sql)?;
        if healthy != "ok" {
            return Err("saved local database is damaged; it was not replaced".into());
        }
        db.execute_batch("COMMIT;").map_err(sql)?;
        Ok(Self(db))
    }

    pub fn bytes(&self) -> Result<Vec<u8>> {
        Ok(self.0.serialize(MAIN_DB).map_err(sql)?.to_vec())
    }

    pub fn document(&self, name: &str) -> Result<Document> {
        valid_name(name)?;
        Ok(self
            .0
            .query_row(
                "SELECT revision,value FROM documents WHERE name=?1",
                [name],
                |row| {
                    Ok(Document {
                        revision: row.get(0)?,
                        value: row.get(1)?,
                    })
                },
            )
            .optional()
            .map_err(sql)?
            .unwrap_or(Document {
                revision: 0,
                value: None,
            }))
    }

    pub fn save_document(
        &mut self,
        name: &str,
        expected: i64,
        value: Option<&[u8]>,
    ) -> Result<i64> {
        valid_name(name)?;
        let next = expected
            .checked_add(1)
            .filter(|n| *n > 0)
            .ok_or("local document revision exhausted")?;
        let transaction = self
            .0
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sql)?;
        let actual: i64 = transaction
            .query_row(
                "SELECT revision FROM documents WHERE name=?1",
                [name],
                |row| row.get(0),
            )
            .optional()
            .map_err(sql)?
            .unwrap_or(0);
        if actual != expected {
            return Err("local state changed in another instance; restart before writing".into());
        }
        transaction.execute("INSERT INTO documents(name,revision,value) VALUES(?1,?2,?3) ON CONFLICT(name) DO UPDATE SET revision=excluded.revision,value=excluded.value",
            params![name,next,value]).map_err(sql)?;
        transaction.commit().map_err(sql)?;
        Ok(next)
    }

    pub fn log(&self, name: &str) -> Result<Document> {
        valid_name(name)?;
        let revision = self
            .0
            .query_row(
                "SELECT revision FROM streams WHERE name=?1",
                [name],
                |row| row.get(0),
            )
            .optional()
            .map_err(sql)?
            .unwrap_or(0);
        if revision == 0 {
            return Ok(Document {
                revision,
                value: None,
            });
        }
        let mut statement = self
            .0
            .prepare("SELECT value FROM frames WHERE stream=?1 ORDER BY position")
            .map_err(sql)?;
        let chunks = statement
            .query_map([name], |row| row.get::<_, Vec<u8>>(0))
            .map_err(sql)?;
        let mut bytes = Vec::new();
        for chunk in chunks {
            bytes.extend(chunk.map_err(sql)?);
        }
        Ok(Document {
            revision,
            value: Some(bytes),
        })
    }

    /// Legacy import is a single transaction. The caller keeps the old file;
    /// unreadable tails remain visible to the existing codec recovery flow.
    pub fn import_log(&mut self, name: &str, bytes: &[u8]) -> Result<()> {
        valid_name(name)?;
        let transaction = self
            .0
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sql)?;
        let inserted = transaction
            .execute(
                "INSERT INTO streams(name,revision) VALUES(?1,1) ON CONFLICT DO NOTHING",
                [name],
            )
            .map_err(sql)?;
        if inserted != 0 {
            transaction
                .execute(
                    "INSERT INTO frames(stream,position,value) VALUES(?1,0,?2)",
                    params![name, bytes],
                )
                .map_err(sql)?;
        }
        transaction.commit().map_err(sql)
    }

    pub fn append(&mut self, name: &str, expected: i64, frame: &[u8]) -> Result<i64> {
        valid_name(name)?;
        if frame.is_empty() {
            return Err("cannot append an empty event frame".into());
        }
        let next = expected
            .checked_add(1)
            .filter(|n| *n > 1)
            .ok_or("local log revision exhausted")?;
        let transaction = self
            .0
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sql)?;
        if transaction
            .execute(
                "UPDATE streams SET revision=?1 WHERE name=?2 AND revision=?3",
                params![next, name, expected],
            )
            .map_err(sql)?
            != 1
        {
            return Err("local log changed in another instance; restart before writing".into());
        }
        transaction
            .execute(
                "INSERT INTO frames(stream,position,value) VALUES(?1,?2,?3)",
                params![name, next, frame],
            )
            .map_err(sql)?;
        transaction.commit().map_err(sql)?;
        Ok(next)
    }

    pub fn recover_prefix(
        &mut self,
        name: &str,
        expected: i64,
        expected_length: usize,
        valid_length: usize,
    ) -> Result<i64> {
        if valid_length > expected_length {
            return Err("invalid recovery prefix length".into());
        }
        let current = self.log(name)?;
        let bytes = current.value.ok_or("local log has not been imported")?;
        if current.revision != expected || bytes.len() != expected_length {
            return Err("local log changed during recovery".into());
        }
        if valid_length == expected_length {
            return Ok(expected);
        }
        let next = expected
            .checked_add(1)
            .ok_or("local log revision exhausted")?;
        let transaction = self
            .0
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sql)?;
        if transaction
            .execute(
                "UPDATE streams SET revision=?1 WHERE name=?2 AND revision=?3",
                params![next, name, expected],
            )
            .map_err(sql)?
            != 1
        {
            return Err("local log changed during recovery".into());
        }
        transaction
            .execute(
                "INSERT INTO recoveries(stream,original) VALUES(?1,?2)",
                params![name, &bytes],
            )
            .map_err(sql)?;
        transaction
            .execute("DELETE FROM frames WHERE stream=?1", [name])
            .map_err(sql)?;
        transaction
            .execute(
                "INSERT INTO frames(stream,position,value) VALUES(?1,0,?2)",
                params![name, &bytes[..valid_length]],
            )
            .map_err(sql)?;
        transaction.commit().map_err(sql)?;
        Ok(next)
    }
}

fn valid_name(name: &str) -> Result<()> {
    if name.is_empty() || name.len() > 256 || name.contains('\0') {
        return Err("invalid local storage name".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serialized_sqlite_preserves_append_order_and_documents() {
        let mut db = Database::from_bytes(&[]).unwrap();
        db.import_log("ledger", b"old").unwrap();
        assert_eq!(db.append("ledger", 1, b"new").unwrap(), 2);
        db.save_document("sealed-household", 0, Some(b"ciphertext"))
            .unwrap();
        let saved = db.bytes().unwrap();
        let mut restarted = Database::from_bytes(&saved).unwrap();
        assert_eq!(restarted.log("ledger").unwrap().value.unwrap(), b"oldnew");
        assert_eq!(
            restarted
                .document("sealed-household")
                .unwrap()
                .value
                .unwrap(),
            b"ciphertext"
        );
        restarted
            .import_log("ledger", b"stale legacy file")
            .unwrap();
        assert_eq!(restarted.log("ledger").unwrap().value.unwrap(), b"oldnew");
    }

    #[test]
    fn stale_writers_and_deletion_cannot_rewind_saved_state() {
        let mut db = Database::from_bytes(&[]).unwrap();
        db.save_document("household", 0, Some(b"new ratchet"))
            .unwrap();
        let saved = db.bytes().unwrap();
        assert!(
            db.save_document("household", 0, Some(b"old ratchet"))
                .is_err()
        );
        assert_eq!(db.bytes().unwrap(), saved);
        db.save_document("household", 1, None).unwrap();
        assert_eq!(
            db.document("household").unwrap(),
            Document {
                revision: 2,
                value: None
            }
        );
        assert!(
            db.save_document("household", 0, Some(b"old legacy copy"))
                .is_err()
        );
    }

    #[test]
    fn recovery_archives_original_and_rejects_changed_logs() {
        let mut db = Database::from_bytes(&[]).unwrap();
        db.import_log("ledger", b"validtorn").unwrap();
        assert_eq!(db.recover_prefix("ledger", 1, 9, 5).unwrap(), 2);
        assert_eq!(db.log("ledger").unwrap().value.unwrap(), b"valid");
        let archived: Vec<u8> =
            db.0.query_row("SELECT original FROM recoveries", [], |row| row.get(0))
                .unwrap();
        assert_eq!(archived, b"validtorn");
        assert!(db.recover_prefix("ledger", 1, 5, 0).is_err());
        assert!(db.append("ledger", 1, b"stale").is_err());
        db.append("ledger", 2, b"next").unwrap();
        assert_eq!(db.log("ledger").unwrap().value.unwrap(), b"validnext");
    }

    #[test]
    fn failed_frame_insert_rolls_back_its_revision_and_history() {
        let mut db = Database::from_bytes(&[]).unwrap();
        db.import_log("ledger", b"before").unwrap();
        db.0.execute_batch("CREATE TRIGGER synthetic_failure BEFORE INSERT ON frames BEGIN SELECT RAISE(ABORT,'synthetic disk failure'); END").unwrap();
        let saved = db.bytes().unwrap();
        assert!(db.append("ledger", 1, b"not committed").is_err());
        assert_eq!(
            db.log("ledger").unwrap(),
            Document {
                revision: 1,
                value: Some(b"before".to_vec())
            }
        );
        assert_eq!(db.bytes().unwrap(), saved);
    }

    #[test]
    fn damaged_or_foreign_databases_are_never_reset() {
        assert!(Database::from_bytes(b"broken").is_err());
        let connection = Connection::open_in_memory().unwrap();
        connection
            .execute_batch("CREATE TABLE unrelated(value TEXT)")
            .unwrap();
        assert!(Database::from_bytes(&connection.serialize(MAIN_DB).unwrap()).is_err());
    }

    #[cfg(not(target_arch = "wasm32"))]
    #[test]
    fn interrupted_process_child() {
        let Ok(path) = std::env::var("CASH_SQLITE_CRASH_TEST_PATH") else {
            return;
        };
        let mut db = Database::open(path).unwrap();
        if std::env::var("CASH_SQLITE_CRASH_TEST_PHASE").unwrap() == "before" {
            db.0.execute_batch("BEGIN IMMEDIATE; UPDATE streams SET revision=2 WHERE name='ledger'; INSERT INTO frames(stream,position,value) VALUES('ledger',2,x'6e657874');").unwrap();
        } else {
            db.append("ledger", 1, b"next").unwrap();
        }
        // Abrupt process exit intentionally bypasses connection/transaction
        // destructors. This checks recovery, not physical power-loss behavior.
        std::process::exit(77);
    }

    #[cfg(not(target_arch = "wasm32"))]
    #[test]
    fn process_interruption_preserves_only_committed_frames() {
        for phase in ["before", "after"] {
            let directory = tempfile::tempdir().unwrap();
            let path = directory.path().join("local.sqlite");
            let mut db = Database::open(&path).unwrap();
            db.import_log("ledger", b"initial").unwrap();
            drop(db);
            let status = std::process::Command::new(std::env::current_exe().unwrap())
                .args(["--exact", "tests::interrupted_process_child", "--nocapture"])
                .env("CASH_SQLITE_CRASH_TEST_PATH", &path)
                .env("CASH_SQLITE_CRASH_TEST_PHASE", phase)
                .status()
                .unwrap();
            assert_eq!(status.code(), Some(77));
            let restarted = Database::open(&path).unwrap();
            let log = restarted.log("ledger").unwrap();
            assert_eq!(log.revision, if phase == "before" { 1 } else { 2 });
            assert_eq!(
                log.value.unwrap(),
                if phase == "before" {
                    b"initial".as_slice()
                } else {
                    b"initialnext".as_slice()
                }
            );
        }
    }

    #[cfg(not(target_arch = "wasm32"))]
    #[test]
    fn simultaneous_first_open_keeps_all_documents() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("local.sqlite");
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(4));
        let handles: Vec<_> = (0..4)
            .map(|index| {
                let path = path.clone();
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    let mut db = Database::open(path).unwrap();
                    db.save_document(&format!("worker-{index}"), 0, Some(b"saved"))
                        .unwrap();
                })
            })
            .collect();
        for handle in handles {
            handle.join().unwrap();
        }
        let db = Database::open(path).unwrap();
        for index in 0..4 {
            assert_eq!(
                db.document(&format!("worker-{index}"))
                    .unwrap()
                    .value
                    .unwrap(),
                b"saved"
            );
        }
    }

    #[cfg(not(target_arch = "wasm32"))]
    #[test]
    fn file_restart_and_two_connections_use_atomic_revision_checks() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("local.sqlite");
        let mut first = Database::open(&path).unwrap();
        let mut second = Database::open(&path).unwrap();
        first.import_log("ledger", b"initial").unwrap();
        first.append("ledger", 1, b"next").unwrap();
        assert!(second.append("ledger", 1, b"stale").is_err());
        first
            .save_document("household", 0, Some(b"sealed"))
            .unwrap();
        assert!(
            second
                .save_document("household", 0, Some(b"rewind"))
                .is_err()
        );
        drop(first);
        drop(second);
        let restarted = Database::open(path).unwrap();
        assert_eq!(
            restarted.log("ledger").unwrap().value.unwrap(),
            b"initialnext"
        );
        assert_eq!(
            restarted.document("household").unwrap().value.unwrap(),
            b"sealed"
        );
    }
}
