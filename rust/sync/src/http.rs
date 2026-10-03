use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde_json::{Value, json};

use crate::relay::{MailboxItem, Relay, RelayError};

/// A [`Relay`] that talks to the Cloudflare Worker in `/relay` over HTTP.
pub struct HttpRelay {
    base: String,
    agent: ureq::Agent,
}

impl HttpRelay {
    pub fn new(base_url: &str) -> Self {
        Self {
            base: base_url.trim_end_matches('/').to_owned(),
            // No pooling: connections are cheap next to the round trip, and a
            // pooled connection the server has already closed turns into a
            // spurious "connection reset" on the next call.
            agent: ureq::AgentBuilder::new().max_idle_connections(0).build(),
        }
    }

    fn url(&self, path: &str) -> String {
        format!("{}{path}", self.base)
    }
}

fn unavailable(message: impl ToString) -> RelayError {
    RelayError::Unavailable(message.to_string())
}

fn decode(text: &str) -> Result<Vec<u8>, RelayError> {
    STANDARD.decode(text).map_err(unavailable)
}

fn body(response: ureq::Response) -> Result<Value, RelayError> {
    response.into_json().map_err(unavailable)
}

fn mailbox_reply(
    response: Result<ureq::Response, ureq::Error>,
) -> Result<Option<MailboxItem>, RelayError> {
    match response {
        Ok(response) => {
            let item = body(response)?;
            Ok(Some(MailboxItem {
                group: item["group"]
                    .as_str()
                    .ok_or_else(|| unavailable("item had no group"))?
                    .to_owned(),
                joined_after: item["joined_after"]
                    .as_u64()
                    .ok_or_else(|| unavailable("item had no joined_after"))?,
                welcome: decode(
                    item["welcome"]
                        .as_str()
                        .ok_or_else(|| unavailable("item had no welcome"))?,
                )?,
            }))
        }
        Err(ureq::Error::Status(404, _)) => Ok(None),
        Err(error) => Err(unavailable(error)),
    }
}

struct CheckedPage {
    entries: Vec<(u64, Vec<u8>)>,
    tail: u64,
    more: bool,
}

fn checked_page(page: &Value, after: u64, previous_tail: u64) -> Result<CheckedPage, RelayError> {
    let tail = page["tail"]
        .as_u64()
        .ok_or_else(|| unavailable("invalid log tail"))?;
    let more = page["more"]
        .as_bool()
        .ok_or_else(|| unavailable("invalid continuation"))?;
    if tail < after || tail < previous_tail {
        return Err(unavailable("relay log tail moved backwards"));
    }
    let raw = page["entries"]
        .as_array()
        .ok_or_else(|| unavailable("missing entry list"))?;
    let mut entries = Vec::new();
    let mut cursor = after;
    for entry in raw {
        let sequence = entry["seq"]
            .as_u64()
            .ok_or_else(|| unavailable("invalid entry sequence"))?;
        if Some(sequence) != cursor.checked_add(1) || sequence > tail {
            return Err(unavailable("gap or reordered relay log"));
        }
        let blob = decode(
            entry["blob"]
                .as_str()
                .ok_or_else(|| unavailable("entry had no blob"))?,
        )?;
        if blob.is_empty() || blob.len() > 256 * 1024 {
            return Err(unavailable("invalid entry size"));
        }
        entries.push((sequence, blob));
        cursor = sequence;
    }
    if more != (cursor < tail) || (more && cursor == after) {
        return Err(unavailable("inconsistent relay continuation"));
    }
    Ok(CheckedPage {
        entries,
        tail,
        more,
    })
}

impl Relay for HttpRelay {
    fn append(
        &mut self,
        group: &str,
        expected_tail: u64,
        blob: Vec<u8>,
    ) -> Result<u64, RelayError> {
        let result = self
            .agent
            .post(&self.url(&format!("/g/{group}/append")))
            .send_json(json!({
                "expected_tail": expected_tail,
                "blob": STANDARD.encode(blob),
            }));
        match result {
            Ok(response) => body(response)?["seq"]
                .as_u64()
                .ok_or_else(|| unavailable("append reply had no seq")),
            Err(ureq::Error::Status(409, response)) => {
                let tail = body(response)?["tail"]
                    .as_u64()
                    .ok_or_else(|| unavailable("conflict reply had no tail"))?;
                Err(RelayError::Conflict { tail })
            }
            Err(error) => Err(unavailable(error)),
        }
    }

    fn read_after(&self, group: &str, after: u64) -> Result<Vec<(u64, Vec<u8>)>, RelayError> {
        let mut entries = Vec::new();
        let mut cursor = after;
        let mut previous_tail = after;
        loop {
            let raw = body(
                self.agent
                    .get(&self.url(&format!("/g/{group}?after={cursor}")))
                    .call()
                    .map_err(unavailable)?,
            )?;
            let page = checked_page(&raw, cursor, previous_tail)?;
            if let Some((sequence, _)) = page.entries.last() {
                cursor = *sequence;
            }
            previous_tail = page.tail;
            entries.extend(page.entries);
            if !page.more {
                return Ok(entries);
            }
        }
    }

    fn put_mailbox(&mut self, mailbox: &str, item: MailboxItem) -> Result<(), RelayError> {
        self.agent
            .put(&self.url(&format!("/m/{mailbox}")))
            .send_json(json!({
                "group": item.group,
                "joined_after": item.joined_after,
                "welcome": STANDARD.encode(item.welcome),
            }))
            .map(|_| ())
            .map_err(unavailable)
    }

    fn take_mailbox(&mut self, mailbox: &str) -> Result<Option<MailboxItem>, RelayError> {
        mailbox_reply(
            self.agent
                .post(&self.url(&format!("/m/{mailbox}/take")))
                .send_json(json!({})),
        )
    }

    fn peek_mailbox(&self, mailbox: &str) -> Result<Option<MailboxItem>, RelayError> {
        mailbox_reply(self.agent.get(&self.url(&format!("/m/{mailbox}"))).call())
    }

    fn acknowledge_mailbox(&mut self, mailbox: &str) -> Result<(), RelayError> {
        match self
            .agent
            .post(&self.url(&format!("/m/{mailbox}/ack")))
            .send_json(json!({}))
        {
            Ok(_) | Err(ureq::Error::Status(404, _)) => Ok(()),
            Err(error) => Err(unavailable(error)),
        }
    }
}

#[cfg(test)]
#[path = "http_page_tests.rs"]
mod page_tests;
