use std::sync::Mutex;

use flutter_rust_bridge::frb;

use crate::crypto::SpikeState;

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// An isolated in-memory MLS run. Each Flutter call acts on the same two peers.
#[frb(opaque)]
pub struct MlsSpike {
    state: Mutex<SpikeState>,
}

pub fn create_group() -> Result<MlsSpike, String> {
    Ok(MlsSpike {
        state: Mutex::new(SpikeState::new()?),
    })
}

pub fn add_member(spike: &MlsSpike) -> Result<bool, String> {
    spike
        .state
        .lock()
        .map_err(|_| "MLS spike state lock was poisoned".to_owned())?
        .add_member()
}

pub fn remove_member_and_verify(spike: &MlsSpike) -> Result<bool, String> {
    spike
        .state
        .lock()
        .map_err(|_| "MLS spike state lock was poisoned".to_owned())?
        .remove_member_and_verify()
}
