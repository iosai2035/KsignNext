#!/usr/bin/env bash
# Ksign Next — build the Rust Apple-refresh core into an XCFramework.
#
# Mirrors Documentation/Phase1-FFI-Design.md §8.2 exactly; the CI workflow
# step and local/mac runs use these same commands. Run from anywhere:
#   Scripts/build_rust_core.sh
# Requires: rustup + Xcode (macOS runner). The Linux VM cannot build the
# iOS targets — CI is the real test.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

rustup toolchain install stable
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios-sim
rustc --version; cargo --version

# First-run bootstrap: the design pins versions with a committed Cargo.lock
# and builds with --locked. If the lock does not exist yet (it is generated
# with `cargo generate-lockfile` on a machine with cargo, before the first
# push), generate it once here instead of failing the build.
if [ ! -f RustCore/apple_refresh/Cargo.lock ]; then
  echo "Cargo.lock missing — generating it once with 'cargo generate-lockfile' (first run only)."
  (cd RustCore/apple_refresh && cargo generate-lockfile)
fi

cd RustCore/apple_refresh
cargo build --release --locked --target aarch64-apple-ios
cargo build --release --locked --target aarch64-apple-ios-sim
cargo build --release --locked --target x86_64-apple-ios-sim
cd ../..
xcodebuild -create-xcframework \
  -library RustCore/apple_refresh/target/aarch64-apple-ios/release/libapple_refresh.a \
  -headers RustCore/apple_refresh/include \
  -library RustCore/apple_refresh/target/aarch64-apple-ios-sim/release/libapple_refresh.a \
  -headers RustCore/apple_refresh/include \
  -library RustCore/apple_refresh/target/x86_64-apple-ios-sim/release/libapple_refresh.a \
  -headers RustCore/apple_refresh/include \
  -output RustCore/AppleRefresh.xcframework
ls -R RustCore/AppleRefresh.xcframework
