use std::sync::{Mutex, MutexGuard};

use cash_core::{
    CategoryId, CategoryUpsert, HybridTimestamp, decode_category_log, encode_category_frame,
    fold_categories,
};
use flutter_rust_bridge::frb;

/// Categories are soft state, kept in their own durable log and folded by
/// last-writer-wins (see `cash_core::categories`) rather than the financial
/// ledger's strict, error-on-conflict fold. `CategoryBook` is deliberately a
/// separate opaque type from `PersonalLedger`: the two states have different
/// guarantees and are never merged into one mechanism.
#[frb(opaque)]
pub struct CategoryBook {
    data: Mutex<CategoryBookData>,
}

struct CategoryBookData {
    actor_id: String,
    upserts: Vec<CategoryUpsert>,
    last_timestamp: HybridTimestamp,
    recovered_upsert_count: u64,
    truncated_bytes: u64,
}

#[derive(Debug, PartialEq)]
pub struct CategoryView {
    pub id: String,
    pub name: String,
    pub icon_key: String,
}

/// The result of a mutation that appended one upsert. `appended_frame` is
/// the durable-log frame for that upsert; the caller (Dart) must append
/// these bytes to its durable store before treating the mutation as
/// committed, the same protocol `ledger::LedgerMutation` uses.
pub struct CategoryMutation {
    pub categories: Vec<CategoryView>,
    pub appended_frame: Vec<u8>,
}

/// Diagnostics from the load that produced a category book's current state.
pub struct CategoryLoadReport {
    pub categories: Vec<CategoryView>,
    pub recovered_upsert_count: u64,
    pub truncated_bytes: u64,
}

/// Opens a category book by replaying a durable log's bytes. Pass an empty
/// `log_bytes` for a brand-new installation; this is the only constructor,
/// so first launch and every later restart share one code path, matching
/// `ledger::load_personal_ledger`.
pub fn load_category_book(actor_id: String, log_bytes: Vec<u8>) -> Result<CategoryBook, String> {
    if actor_id.trim().is_empty() {
        return Err("actor ID cannot be empty".to_owned());
    }
    let decoded = decode_category_log(&log_bytes);
    let last_timestamp = decoded
        .upserts
        .iter()
        .map(|upsert| upsert.timestamp)
        .max()
        .unwrap_or(HybridTimestamp::new(0, 0));
    let recovered_upsert_count = decoded.upserts.len() as u64;

    Ok(CategoryBook {
        data: Mutex::new(CategoryBookData {
            actor_id,
            upserts: decoded.upserts,
            last_timestamp,
            recovered_upsert_count,
            truncated_bytes: decoded.trailing_garbage_bytes as u64,
        }),
    })
}

/// Reports what a completed [`load_category_book`] call recovered.
pub fn category_load_report(book: &CategoryBook) -> Result<CategoryLoadReport, String> {
    let data = lock(book)?;
    Ok(CategoryLoadReport {
        categories: data.views(),
        recovered_upsert_count: data.recovered_upsert_count,
        truncated_bytes: data.truncated_bytes,
    })
}

/// Creates or updates a category's name and icon. `category_id` is a stable
/// key the caller chooses once (e.g. a slug); calling this again with the
/// same ID always upserts rather than duplicating.
pub fn upsert_category(
    book: &CategoryBook,
    category_id: String,
    name: String,
    icon_key: String,
    wall_clock_millis: i64,
) -> Result<CategoryMutation, String> {
    let name = name.trim().to_owned();
    if name.is_empty() {
        return Err("category name cannot be empty".to_owned());
    }
    if category_id.trim().is_empty() {
        return Err("category ID cannot be empty".to_owned());
    }

    let mut data = lock(book)?;
    let timestamp = data.next_timestamp(wall_clock_millis)?;
    let event_id = format!(
        "{}-{:016x}-{:08x}",
        data.actor_id, timestamp.physical_millis, timestamp.logical
    );
    let upsert = CategoryUpsert::new(
        event_id,
        data.actor_id.clone(),
        timestamp.physical_millis,
        timestamp.logical,
        CategoryId::new(category_id),
        name,
        icon_key,
    );
    let appended_frame = encode_category_frame(&upsert);
    data.upserts.push(upsert);
    Ok(CategoryMutation {
        categories: data.views(),
        appended_frame,
    })
}

pub fn list_categories(book: &CategoryBook) -> Result<Vec<CategoryView>, String> {
    Ok(lock(book)?.views())
}

fn lock(book: &CategoryBook) -> Result<MutexGuard<'_, CategoryBookData>, String> {
    book.data
        .lock()
        .map_err(|_| "category book lock was poisoned".to_owned())
}

impl CategoryBookData {
    fn next_timestamp(&mut self, wall_clock_millis: i64) -> Result<HybridTimestamp, String> {
        let timestamp = self
            .last_timestamp
            .checked_next(wall_clock_millis)
            .ok_or_else(|| "hybrid clock exhausted".to_owned())?;
        self.last_timestamp = timestamp;
        Ok(timestamp)
    }

    fn views(&self) -> Vec<CategoryView> {
        let state = fold_categories(self.upserts.iter().cloned());
        state
            .categories
            .into_iter()
            .map(|(id, record)| CategoryView {
                id: id.as_str().to_owned(),
                name: record.name,
                icon_key: record.icon_key,
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loading_tied_category_frames_converges_and_keeps_clock_progress() {
        let frames: Vec<Vec<u8>> = [("a", "Old"), ("z", "Chosen")]
            .into_iter()
            .map(|(id, name)| {
                encode_category_frame(&CategoryUpsert::new(
                    id,
                    "device-a",
                    100,
                    7,
                    CategoryId::new("food"),
                    name,
                    "restaurant",
                ))
            })
            .collect();
        let forward = load_category_book("device-a".into(), frames.concat()).unwrap();
        let backward = load_category_book(
            "device-a".into(),
            frames.iter().rev().flatten().copied().collect(),
        )
        .unwrap();
        assert_eq!(
            list_categories(&forward).unwrap(),
            list_categories(&backward).unwrap()
        );
        assert_eq!(list_categories(&forward).unwrap()[0].name, "Chosen");
        let edited = upsert_category(
            &backward,
            "food".into(),
            "Reviewed".into(),
            "shopping_cart".into(),
            1,
        )
        .unwrap();
        assert_eq!(edited.categories[0].name, "Reviewed");
        let decoded = decode_category_log(&edited.appended_frame);
        assert_eq!(decoded.upserts[0].timestamp, HybridTimestamp::new(100, 8));
        for frame in frames {
            let decoded = decode_category_log(&frame);
            assert_eq!(encode_category_frame(&decoded.upserts[0]), frame);
        }
    }

    #[test]
    fn book_clock_carries_and_refuses_exhaustion() {
        let book = new_book("device-a");
        let mut data = book.data.lock().unwrap();
        data.last_timestamp = HybridTimestamp::new(100, u32::MAX);
        assert_eq!(
            data.next_timestamp(1).unwrap(),
            HybridTimestamp::new(101, 0)
        );
        let exhausted = HybridTimestamp::new(i64::MAX, u32::MAX);
        data.last_timestamp = exhausted;
        assert!(data.next_timestamp(1).is_err());
        assert_eq!(data.last_timestamp, exhausted);
    }

    fn new_book(actor_id: &str) -> CategoryBook {
        load_category_book(actor_id.to_owned(), Vec::new()).unwrap()
    }

    #[test]
    fn upserting_a_category_makes_it_listable() {
        let book = new_book("device-a");
        let mutation = upsert_category(
            &book,
            "food".to_owned(),
            "Food".to_owned(),
            "restaurant".to_owned(),
            1,
        )
        .unwrap();
        assert_eq!(mutation.categories.len(), 1);
        assert_eq!(mutation.categories[0].name, "Food");

        let listed = list_categories(&book).unwrap();
        assert_eq!(listed, mutation.categories);
    }

    #[test]
    fn upserting_the_same_id_again_replaces_it() {
        let book = new_book("device-a");
        upsert_category(
            &book,
            "food".to_owned(),
            "Food".to_owned(),
            "restaurant".to_owned(),
            1,
        )
        .unwrap();
        let mutation = upsert_category(
            &book,
            "food".to_owned(),
            "Groceries".to_owned(),
            "shopping_cart".to_owned(),
            2,
        )
        .unwrap();
        assert_eq!(mutation.categories.len(), 1);
        assert_eq!(mutation.categories[0].name, "Groceries");
    }

    #[test]
    fn an_empty_name_is_rejected_and_never_persisted() {
        let book = new_book("device-a");
        assert!(
            upsert_category(&book, "food".to_owned(), "  ".to_owned(), "".to_owned(), 1).is_err()
        );
        assert!(list_categories(&book).unwrap().is_empty());
    }

    #[test]
    fn restart_recovers_identical_categories_from_persisted_frames() {
        let book = new_book("device-a");
        let mut log = Vec::new();
        log.extend(
            upsert_category(
                &book,
                "food".to_owned(),
                "Food".to_owned(),
                "restaurant".to_owned(),
                1,
            )
            .unwrap()
            .appended_frame,
        );
        log.extend(
            upsert_category(
                &book,
                "transport".to_owned(),
                "Transport".to_owned(),
                "directions_car".to_owned(),
                2,
            )
            .unwrap()
            .appended_frame,
        );

        let restarted = load_category_book("device-a".to_owned(), log).unwrap();
        let report = category_load_report(&restarted).unwrap();
        assert_eq!(report.recovered_upsert_count, 2);
        assert_eq!(report.truncated_bytes, 0);
        assert_eq!(report.categories.len(), 2);
    }
}
