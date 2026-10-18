#!/usr/bin/env bash
# Source in each agent shell: setup-script exports do not persist everywhere.
cash_cloud_env_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Reuse a workspace-installed Rust manager when the platform keeps HOME read
# only. Explicit user bindings always win; never change rustup's global default.
if [[ -z "${CARGO_HOME:-}" && -x /workspace/toolchains/cargo/bin/rustup ]]; then
  export CARGO_HOME=/workspace/toolchains/cargo
  if [[ -z "${RUSTUP_HOME:-}" && -d /workspace/toolchains/rustup ]]; then
    export RUSTUP_HOME=/workspace/toolchains/rustup
  fi
fi
cash_cloud_cache="$cash_cloud_env_root/.toolchains/cloud/cache"
# Respect explicit caches and reuse the prepared workspace caches. These
# supported overrides avoid Flutter/analyzer writes into the host home path.
if [[ -z "${PUB_CACHE:-}" ]]; then
  if [[ -d /workspace/.cache/pub ]]; then
    export PUB_CACHE=/workspace/.cache/pub
  else
    export PUB_CACHE="$cash_cloud_cache/pub"
  fi
fi
if [[ -z "${npm_config_cache:-}" ]]; then
  if [[ -d /workspace/.cache/npm ]]; then
    export npm_config_cache=/workspace/.cache/npm
  else
    export npm_config_cache="$cash_cloud_cache/npm"
  fi
fi
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$cash_cloud_cache/config}"
export ANALYZER_STATE_LOCATION_OVERRIDE="${ANALYZER_STATE_LOCATION_OVERRIDE:-$cash_cloud_cache/analyzer}"
export PATH="$cash_cloud_env_root/.toolchains/cloud/node-v24.19.0-linux-x64/bin:$cash_cloud_env_root/.toolchains/cloud/flutter/bin:${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
export RUSTUP_TOOLCHAIN=1.98.1
export CARGO_BUILD_JOBS=2
export CI=true
export FLUTTER_SUPPRESS_ANALYTICS=true
unset cash_cloud_env_root cash_cloud_cache
