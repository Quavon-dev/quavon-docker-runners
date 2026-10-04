#!/usr/bin/env bash
# flavors: full full-plus
# Rust stable via rustup, owned by the runner user so jobs can add targets.
source "$(dirname "$0")/lib.sh"

log "Rust"
export RUSTUP_HOME=/usr/share/rust/.rustup CARGO_HOME=/usr/share/rust/.cargo
install -d -o runner -g runner /usr/share/rust
as_runner env RUSTUP_HOME="$RUSTUP_HOME" CARGO_HOME="$CARGO_HOME" \
  bash -c 'curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --component rustfmt,clippy --no-modify-path'
add_env RUSTUP_HOME "$RUSTUP_HOME"
add_env CARGO_HOME "$CARGO_HOME"
add_path "$CARGO_HOME/bin"
