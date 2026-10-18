#!/usr/bin/env bash
# Source in each agent shell: setup-script exports do not persist everywhere.
cash_cloud_env_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$cash_cloud_env_root/.toolchains/cloud/node-v24.19.0-linux-x64/bin:$cash_cloud_env_root/.toolchains/cloud/flutter/bin:$HOME/.cargo/bin:$PATH"
export RUSTUP_TOOLCHAIN=1.98.1
export CARGO_BUILD_JOBS=2
export CI=true
export FLUTTER_SUPPRESS_ANALYTICS=true
unset cash_cloud_env_root
