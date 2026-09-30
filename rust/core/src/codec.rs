//! Durable event log codec.
//!
//! Persistence itself (files on native platforms, a browser-side store on
//! web) is the caller's job; this module only defines the byte-identical,
//! self-checking wire shape events take when they leave memory. Each event
//! becomes one length-prefixed, checksummed frame, so an append-only writer
//! (a native file opened in append mode, or a browser object store) can add
//! frames one at a time without ever rewriting earlier bytes.
//!
//! A torn write (the process dies mid-`flush`) can only ever corrupt the
//! last, still-in-flight frame. Decoding therefore stops at the first frame
//! that fails its checksum or runs out of bytes and reports how many trailing
//! bytes were unreadable, instead of discarding the whole log or panicking.
//! A conflict between two fully valid frames (for example the same event ID
//! with different content) is a different problem — real data corruption,
//! not a torn write — and is left for `fold`/`Snapshot` to reject.

use crate::bytes_io::{Reader, write_bool, write_i64, write_string, write_u32};
use crate::frame::{DecodedFrameLog, decode_frame_log, encode_frame};
use crate::{
    AccountId, Currency, Event, EventKind, FxRate, Money, RoundingRule, TransactionId,
    TransactionKind,
};

const KIND_ACCOUNT_OPENED: u8 = 0;
const KIND_TRANSACTION_RECORDED: u8 = 1;
const KIND_AMOUNT_ADJUSTED: u8 = 2;
const KIND_CATEGORY_ASSIGNED: u8 = 3;
const KIND_TRANSACTION_VOIDED: u8 = 4;
const KIND_TRANSFER_RECORDED: u8 = 5;

/// The result of decoding a durable log's bytes back into events.
pub struct DecodedLog {
    pub events: Vec<Event>,
    /// Bytes at the tail of the log that were not a complete, checksum-valid
    /// frame. Expected after a crash mid-write; the safe recovery is to keep
    /// every event decoded before this point and drop only this remainder.
    pub trailing_garbage_bytes: usize,
}

impl From<DecodedFrameLog<Event>> for DecodedLog {
    fn from(decoded: DecodedFrameLog<Event>) -> Self {
        Self {
            events: decoded.items,
            trailing_garbage_bytes: decoded.trailing_garbage_bytes,
        }
    }
}

/// Encodes one event as a self-contained, checksummed frame ready to append
/// to a durable log. The same event always encodes to the same bytes.
pub fn encode_event_frame(event: &Event) -> Vec<u8> {
    encode_frame(&encode_event(event))
}

/// Decodes a byte buffer made of zero or more frames written by
/// [`encode_event_frame`], back-to-back, in append order.
pub fn decode_event_log(bytes: &[u8]) -> DecodedLog {
    decode_frame_log(bytes, decode_event).into()
}

pub(crate) fn encode_event(event: &Event) -> Vec<u8> {
    let mut bytes = Vec::new();
    write_string(&mut bytes, event.id.as_str());
    write_string(&mut bytes, event.actor_id.as_str());
    write_i64(&mut bytes, event.timestamp.physical_millis);
    write_u32(&mut bytes, event.timestamp.logical);
    encode_kind(&mut bytes, &event.kind);
    bytes
}

pub(crate) fn decode_event(payload: &[u8]) -> Option<Event> {
    let mut reader = Reader::new(payload);
    let id = reader.read_string()?;
    let actor_id = reader.read_string()?;
    let physical_millis = reader.read_i64()?;
    let logical = reader.read_u32()?;
    let kind = decode_kind(&mut reader)?;
    if reader.remaining() != 0 {
        return None;
    }
    Some(Event::new(id, actor_id, physical_millis, logical, kind))
}

fn encode_kind(bytes: &mut Vec<u8>, kind: &EventKind) {
    match kind {
        EventKind::AccountOpened {
            account_id,
            name,
            currency,
        } => {
            bytes.push(KIND_ACCOUNT_OPENED);
            write_string(bytes, account_id.as_str());
            write_string(bytes, name);
            write_string(bytes, currency.code());
        }
        EventKind::TransactionRecorded {
            transaction_id,
            account_id,
            kind,
            original,
            reporting_fx,
            title,
            category_id,
            recurring_id,
        } => {
            bytes.push(KIND_TRANSACTION_RECORDED);
            write_string(bytes, transaction_id.as_str());
            write_string(bytes, account_id.as_str());
            write_bool(bytes, matches!(kind, TransactionKind::Income));
            write_money(bytes, original);
            write_fx_rate(bytes, reporting_fx);
            write_string(bytes, title);
            write_option_string(bytes, category_id.as_deref());
            write_option_string(bytes, recurring_id.as_deref());
        }
        EventKind::AmountAdjusted {
            transaction_id,
            original,
            reporting_fx,
        } => {
            bytes.push(KIND_AMOUNT_ADJUSTED);
            write_string(bytes, transaction_id.as_str());
            write_money(bytes, original);
            write_fx_rate(bytes, reporting_fx);
        }
        EventKind::CategoryAssigned {
            transaction_id,
            category_id,
        } => {
            bytes.push(KIND_CATEGORY_ASSIGNED);
            write_string(bytes, transaction_id.as_str());
            write_option_string(bytes, category_id.as_deref());
        }
        EventKind::TransactionVoided { transaction_id } => {
            bytes.push(KIND_TRANSACTION_VOIDED);
            write_string(bytes, transaction_id.as_str());
        }
        EventKind::TransferRecorded {
            transfer_id,
            from_account_id,
            to_account_id,
            sent,
            sent_reporting_fx,
            received,
            received_reporting_fx,
            title,
        } => {
            bytes.push(KIND_TRANSFER_RECORDED);
            write_string(bytes, transfer_id.as_str());
            write_string(bytes, from_account_id.as_str());
            write_string(bytes, to_account_id.as_str());
            write_money(bytes, sent);
            write_fx_rate(bytes, sent_reporting_fx);
            write_money(bytes, received);
            write_fx_rate(bytes, received_reporting_fx);
            write_string(bytes, title);
        }
    }
}

fn decode_kind(reader: &mut Reader<'_>) -> Option<EventKind> {
    match reader.read_u8()? {
        KIND_ACCOUNT_OPENED => Some(EventKind::AccountOpened {
            account_id: AccountId::new(reader.read_string()?),
            name: reader.read_string()?,
            currency: read_currency(reader)?,
        }),
        KIND_TRANSACTION_RECORDED => {
            let transaction_id = TransactionId::new(reader.read_string()?);
            let account_id = AccountId::new(reader.read_string()?);
            let kind = read_transaction_kind(reader)?;
            let original = read_money(reader)?;
            let reporting_fx = read_fx_rate(reader)?;
            let title = reader.read_string()?;
            let category_id = read_option_string(reader)?;
            let recurring_id = read_option_string(reader)?;
            Some(EventKind::TransactionRecorded {
                transaction_id,
                account_id,
                kind,
                original,
                reporting_fx,
                title,
                category_id,
                recurring_id,
            })
        }
        KIND_AMOUNT_ADJUSTED => Some(EventKind::AmountAdjusted {
            transaction_id: TransactionId::new(reader.read_string()?),
            original: read_money(reader)?,
            reporting_fx: read_fx_rate(reader)?,
        }),
        KIND_CATEGORY_ASSIGNED => Some(EventKind::CategoryAssigned {
            transaction_id: TransactionId::new(reader.read_string()?),
            category_id: read_option_string(reader)?,
        }),
        KIND_TRANSACTION_VOIDED => Some(EventKind::TransactionVoided {
            transaction_id: TransactionId::new(reader.read_string()?),
        }),
        KIND_TRANSFER_RECORDED => Some(EventKind::TransferRecorded {
            transfer_id: TransactionId::new(reader.read_string()?),
            from_account_id: AccountId::new(reader.read_string()?),
            to_account_id: AccountId::new(reader.read_string()?),
            sent: read_money(reader)?,
            sent_reporting_fx: read_fx_rate(reader)?,
            received: read_money(reader)?,
            received_reporting_fx: read_fx_rate(reader)?,
            title: reader.read_string()?,
        }),
        _ => None,
    }
}

fn write_money(bytes: &mut Vec<u8>, money: &Money) {
    write_i64(bytes, money.minor_units);
    write_string(bytes, money.currency.code());
}

fn read_money(reader: &mut Reader<'_>) -> Option<Money> {
    let minor_units = reader.read_i64()?;
    Some(Money::new(minor_units, read_currency(reader)?))
}

fn write_fx_rate(bytes: &mut Vec<u8>, rate: &FxRate) {
    write_i64(bytes, rate.numerator);
    write_i64(bytes, rate.denominator);
    write_string(bytes, rate.target_currency.code());
    bytes.push(match rate.rounding {
        RoundingRule::HalfAwayFromZero => 0,
    });
}

fn read_fx_rate(reader: &mut Reader<'_>) -> Option<FxRate> {
    let numerator = reader.read_i64()?;
    let denominator = reader.read_i64()?;
    let target_currency = read_currency(reader)?;
    match reader.read_u8()? {
        0 => {}
        _ => return None,
    }
    FxRate::new(numerator, denominator, target_currency).ok()
}

fn read_currency(reader: &mut Reader<'_>) -> Option<Currency> {
    Currency::from_code(&reader.read_string()?).ok()
}

fn read_transaction_kind(reader: &mut Reader<'_>) -> Option<TransactionKind> {
    Some(if reader.read_bool()? {
        TransactionKind::Income
    } else {
        TransactionKind::Expense
    })
}

fn write_option_string(bytes: &mut Vec<u8>, value: Option<&str>) {
    match value {
        Some(value) => {
            write_bool(bytes, true);
            write_string(bytes, value);
        }
        None => write_bool(bytes, false),
    }
}

fn read_option_string(reader: &mut Reader<'_>) -> Option<Option<String>> {
    if reader.read_bool()? {
        Some(Some(reader.read_string()?))
    } else {
        Some(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn usd() -> Currency {
        Currency::from_code("USD").unwrap()
    }

    fn sample_events() -> Vec<Event> {
        vec![
            Event::new(
                "event-account",
                "device-a",
                1_000,
                0,
                EventKind::AccountOpened {
                    account_id: AccountId::new("checking"),
                    name: "Checking".to_owned(),
                    currency: usd(),
                },
            ),
            Event::new(
                "event-transaction",
                "device-a",
                1_001,
                0,
                EventKind::TransactionRecorded {
                    transaction_id: TransactionId::new("groceries-1"),
                    account_id: AccountId::new("checking"),
                    kind: TransactionKind::Expense,
                    original: Money::new(1234, usd()),
                    reporting_fx: FxRate::new(11, 10, usd()).unwrap(),
                    title: "Groceries".to_owned(),
                    category_id: Some("food".to_owned()),
                    recurring_id: None,
                },
            ),
            Event::new(
                "event-transaction-recurring",
                "device-a",
                1_001,
                1,
                EventKind::TransactionRecorded {
                    transaction_id: TransactionId::new("rent-1"),
                    account_id: AccountId::new("checking"),
                    kind: TransactionKind::Expense,
                    original: Money::new(150_000, usd()),
                    reporting_fx: FxRate::identity(usd()),
                    title: "Rent".to_owned(),
                    category_id: None,
                    recurring_id: Some("monthly-rent".to_owned()),
                },
            ),
            Event::new(
                "event-adjust",
                "device-a",
                1_002,
                1,
                EventKind::AmountAdjusted {
                    transaction_id: TransactionId::new("groceries-1"),
                    original: Money::new(1500, usd()),
                    reporting_fx: FxRate::identity(usd()),
                },
            ),
            Event::new(
                "event-category",
                "device-a",
                1_003,
                0,
                EventKind::CategoryAssigned {
                    transaction_id: TransactionId::new("groceries-1"),
                    category_id: None,
                },
            ),
            Event::new(
                "event-void",
                "device-a",
                1_004,
                0,
                EventKind::TransactionVoided {
                    transaction_id: TransactionId::new("groceries-1"),
                },
            ),
            Event::new(
                "event-transfer",
                "device-a",
                1_005,
                0,
                EventKind::TransferRecorded {
                    transfer_id: TransactionId::new("transfer-1"),
                    from_account_id: AccountId::new("checking"),
                    to_account_id: AccountId::new("savings"),
                    sent: Money::new(1000, usd()),
                    sent_reporting_fx: FxRate::identity(usd()),
                    received: Money::new(1000, usd()),
                    received_reporting_fx: FxRate::identity(usd()),
                    title: "Move to savings".to_owned(),
                },
            ),
        ]
    }

    #[test]
    fn every_event_kind_round_trips_through_a_frame() {
        for event in sample_events() {
            let frame = encode_event_frame(&event);
            let decoded = decode_event_log(&frame);
            assert_eq!(decoded.trailing_garbage_bytes, 0);
            assert_eq!(decoded.events, vec![event]);
        }
    }

    #[test]
    fn the_same_event_always_encodes_to_the_same_bytes() {
        let event = sample_events().remove(1);
        assert_eq!(encode_event_frame(&event), encode_event_frame(&event));
    }

    #[test]
    fn a_log_of_many_frames_decodes_back_in_order() {
        let events = sample_events();
        let mut log = Vec::new();
        for event in &events {
            log.extend(encode_event_frame(event));
        }

        let decoded = decode_event_log(&log);
        assert_eq!(decoded.trailing_garbage_bytes, 0);
        assert_eq!(decoded.events, events);
    }

    #[test]
    fn a_truncated_final_frame_is_reported_and_does_not_lose_earlier_events() {
        let events = sample_events();
        let mut log = Vec::new();
        for event in &events[..events.len() - 1] {
            log.extend(encode_event_frame(event));
        }
        let complete_len = log.len();
        // Simulate a crash mid-`flush` of the final frame: only part of it
        // made it to disk.
        let mut last_frame = encode_event_frame(&events[events.len() - 1]);
        last_frame.truncate(last_frame.len() / 2);
        log.extend(&last_frame);

        let decoded = decode_event_log(&log);
        assert_eq!(decoded.events, events[..events.len() - 1]);
        assert_eq!(decoded.trailing_garbage_bytes, log.len() - complete_len);
    }

    #[test]
    fn a_bit_flip_in_a_frame_is_detected_by_its_checksum() {
        let event = sample_events().remove(1);
        let mut frame = encode_event_frame(&event);
        let flip_at = frame.len() - 1;
        frame[flip_at] ^= 0xFF;

        let decoded = decode_event_log(&frame);
        assert!(decoded.events.is_empty());
        assert_eq!(decoded.trailing_garbage_bytes, frame.len());
    }

    #[test]
    fn an_empty_log_decodes_to_no_events_and_no_garbage() {
        let decoded = decode_event_log(&[]);
        assert!(decoded.events.is_empty());
        assert_eq!(decoded.trailing_garbage_bytes, 0);
    }
}
