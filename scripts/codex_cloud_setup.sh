#!/usr/bin/env bash
# Linux x86_64 bootstrap; no deployment, credentials, Actions or mobile builds.
set -euo pipefail
if [[ "${1:-}" == "--help" ]]; then
  printf '%s\n' 'Usage: bash scripts/codex_cloud_setup.sh [--check]' \
    'Installs pinned SDKs in ignored .toolchains/cloud and fetches locked packages.' \
    '--check validates prerequisites/versions only; installs and downloads nothing.'
  exit 0
fi
if [[ $# -gt 1 || ( $# == 1 && "$1" != "--check" ) ]]; then
  printf '%s\n' 'Unknown argument; use --help.' >&2
  exit 2
fi
cash_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$cash_repo_root"
if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
  printf '%s\n' 'This bootstrap supports Linux x86_64 only; do not use on the Windows checkout.' >&2
  exit 2
fi
source scripts/codex_cloud_env.sh
for cash_command in git curl tar xz unzip sha256sum rustup cc pkg-config; do
  if ! command -v "$cash_command" >/dev/null; then
    printf 'Missing prerequisite: %s. Ask the environment setup to install it.\n' "$cash_command" >&2
    exit 2
  fi
done
printf '%s\n' 'Available workspace disk (check before adding mobile/WASM toolchains):'
df -h .
cash_sdk_root="$cash_repo_root/.toolchains/cloud"
cash_node_archive=node-v24.19.0-linux-x64.tar.xz
cash_flutter_revision=6a19cca56475dbfba1478ee68d7bd0c2ef891da1
if [[ "${1:-}" != "--check" ]]; then
  mkdir -p "$cash_sdk_root/downloads"
  if [[ ! -x "$cash_sdk_root/node-v24.19.0-linux-x64/bin/node" ]]; then
    curl --fail --location --retry 2 --max-time 300 \
      "https://nodejs.org/dist/v24.19.0/$cash_node_archive" \
      --output "$cash_sdk_root/downloads/$cash_node_archive"
    curl --fail --location --retry 2 --max-time 60 \
      https://nodejs.org/dist/v24.19.0/SHASUMS256.txt \
      --output "$cash_sdk_root/downloads/SHASUMS256.txt"
    (cd "$cash_sdk_root/downloads"
      grep -E "^[0-9a-f]{64}  $cash_node_archive\$" SHASUMS256.txt | sha256sum --check --status)
    tar -xJf "$cash_sdk_root/downloads/$cash_node_archive" -C "$cash_sdk_root"
  fi
  if [[ ! -e "$cash_sdk_root/flutter" ]]; then
    git clone --branch 3.47.5 --depth 1 https://github.com/flutter/flutter.git "$cash_sdk_root/flutter"
  fi
  [[ "$(git -C "$cash_sdk_root/flutter" rev-parse HEAD)" == "$cash_flutter_revision" ]] || {
    printf '%s\n' 'Flutter revision mismatch; preserve the cache and investigate, do not upgrade.' >&2
    exit 2
  }
  if ! rustup run 1.98.1 rustc --version >/dev/null 2>&1; then
    rustup toolchain install 1.98.1 --profile minimal
  fi
fi
[[ "$(node --version)" == v24.19.0 ]] || { printf '%s\n' 'Expected Node v24.19.0.' >&2; exit 2; }
[[ "$(git -C "$cash_sdk_root/flutter" rev-parse HEAD)" == "$cash_flutter_revision" ]] || exit 2
[[ "$(rustc --version)" == 'rustc 1.98.1 '* ]] || { printf '%s\n' 'Expected Rust 1.98.1.' >&2; exit 2; }
node --version
rustc --version
flutter --no-version-check --version
if [[ "${1:-}" == "--check" ]]; then exit 0; fi
rustup component add rustfmt clippy --toolchain 1.98.1
(cd relay && npm ci --no-audit --no-fund)
cargo fetch --manifest-path rust/Cargo.toml --locked
(cd app && flutter --no-version-check pub get --enforce-lockfile)
printf '%s\n' 'SDK/package setup finished; this is not a test or platform-runtime pass.' \
  'Source scripts/codex_cloud_env.sh in each new shell. Read docs/CLOUD-HANDOFF.md next.'
