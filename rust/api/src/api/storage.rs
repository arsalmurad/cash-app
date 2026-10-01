//! Only these synchronous bridge calls may use SQLite. In particular the
//! browser binding must stay on the Dart caller's one WASM thread, never FRB's
//! multithreaded worker pool. The UI carries bytes, not SQL or financial rows.
use cash_storage::Database;
use flutter_rust_bridge::frb;

pub enum StorageOperation {
    ReadDocument,
    WriteDocument,
    OpenLog,
    AppendFrame,
    RecoverPrefix,
}

pub struct StorageRequest {
    pub name: String,
    pub operation: StorageOperation,
    pub expected_revision: i64,
    pub value: Option<Vec<u8>>,
    pub expected_length: u64,
    pub valid_length: u64,
}

pub struct StorageResponse {
    pub revision: i64,
    pub value: Option<Vec<u8>>,
    /// Empty for native files; web saves the complete SQLite image atomically.
    pub database: Vec<u8>,
}

fn step(db: &mut Database, request: StorageRequest) -> Result<StorageResponse, String> {
    let name = &request.name;
    let result = match request.operation {
        StorageOperation::ReadDocument => db.document(name)?,
        StorageOperation::WriteDocument => {
            let revision =
                db.save_document(name, request.expected_revision, request.value.as_deref())?;
            return Ok(StorageResponse {
                revision,
                value: None,
                database: Vec::new(),
            });
        }
        StorageOperation::OpenLog => {
            // Import exactly once. Retaining the source log permits recovery or
            // rollback, but it can never replace an already-migrated stream.
            db.import_log(name, request.value.as_deref().unwrap_or(&[]))?;
            db.log(name)?
        }
        StorageOperation::AppendFrame => {
            let revision = db.append(
                name,
                request.expected_revision,
                request.value.as_deref().ok_or("missing event frame")?,
            )?;
            return Ok(StorageResponse {
                revision,
                value: None,
                database: Vec::new(),
            });
        }
        StorageOperation::RecoverPrefix => {
            let expected_length = request
                .expected_length
                .try_into()
                .map_err(|_| "log length is too large")?;
            let valid_length = request
                .valid_length
                .try_into()
                .map_err(|_| "recovery prefix is too large")?;
            let revision = db.recover_prefix(
                name,
                request.expected_revision,
                expected_length,
                valid_length,
            )?;
            return Ok(StorageResponse {
                revision,
                value: None,
                database: Vec::new(),
            });
        }
    };
    Ok(StorageResponse {
        revision: result.revision,
        value: result.value,
        database: Vec::new(),
    })
}

#[frb(sync)]
pub fn sqlite_serialized(
    database: Vec<u8>,
    request: StorageRequest,
) -> Result<StorageResponse, String> {
    let mut db = Database::from_bytes(&database)?;
    let mut result = step(&mut db, request)?;
    result.database = db.bytes()?;
    Ok(result)
}

#[frb(sync)]
pub fn sqlite_file(path: String, request: StorageRequest) -> Result<StorageResponse, String> {
    #[cfg(not(target_arch = "wasm32"))]
    {
        step(&mut Database::open(path)?, request)
    }
    #[cfg(target_arch = "wasm32")]
    {
        let _ = (path, request);
        Err("browser storage must use the serialized SQLite bridge".into())
    }
}
