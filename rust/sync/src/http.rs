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
        loop {
            let page = body(
                self.agent
                    .get(&self.url(&format!("/g/{group}?after={cursor}")))
                    .call()
                    .map_err(unavailable)?,
            )?;
            for entry in page["entries"].as_array().into_iter().flatten() {
                let sequence = entry["seq"]
                    .as_u64()
                    .ok_or_else(|| unavailable("entry had no seq"))?;
                let blob = decode(
                    entry["blob"]
                        .as_str()
                        .ok_or_else(|| unavailable("entry had no blob"))?,
                )?;
                cursor = sequence;
                entries.push((sequence, blob));
            }
            if page["more"].as_bool() != Some(true) {
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
