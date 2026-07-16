#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

cache_root="${TMPDIR:-/tmp}/tokenscope-verification"
mkdir -p "$cache_root/clang" "$cache_root/swiftpm" "$cache_root/snapshots"
export CLANG_MODULE_CACHE_PATH="$cache_root/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache_root/swiftpm"

print "Checkpoint 1/5: parse all Swift sources"
swiftc -frontend -parse Sources/TokenScope/*.swift

print "Checkpoint 2/5: model and adaptive-rail regressions"
swiftc Sources/TokenScope/Models.swift \
  Sources/TokenScope/LimitRailPresentation.swift \
  Sources/TokenScope/EventReconciler.swift \
  Sources/TokenScope/PerformanceAggregator.swift \
  Sources/TokenScope/ProcessReaper.swift \
  Sources/TokenScope/Fmt.swift \
  tools/verify-models.swift \
  -o "$cache_root/model-checks"
"$cache_root/model-checks"

print "Checkpoint 3/5: protocol and LM Studio regressions"
swiftc Sources/TokenScope/Models.swift \
  Sources/TokenScope/HTTPRequestScanner.swift \
  Sources/TokenScope/HTTPIdentityEncodingRewriter.swift \
  Sources/TokenScope/HTTPResponseFramer.swift \
  Sources/TokenScope/ResponseScanner.swift \
  tools/verify-protocols.swift \
  -o "$cache_root/protocol-checks"
"$cache_root/protocol-checks"

swiftc Sources/TokenScope/Models.swift \
  Sources/TokenScope/LMStudioEventParser.swift \
  tools/verify-lmstudio.swift \
  -o "$cache_root/lmstudio-checks"
"$cache_root/lmstudio-checks"

if [[ "${CLI_ONLY:-0}" == "1" ]]; then
  print "CLI-only verification complete."
  print "Skipped the app build and snapshots, which require full Xcode."
  exit 0
fi

developer_dir="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
if [[ -z "$developer_dir" || "$developer_dir" == *"/CommandLineTools" ]]; then
  print -u2 "CLI checkpoints passed, but UI verification requires full Xcode."
  print -u2 "Install Xcode, then either select it with:"
  print -u2 "  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
  print -u2 "  sudo xcodebuild -runFirstLaunch"
  print -u2 "or run this script with a beta directly:"
  print -u2 "  DEVELOPER_DIR='/path/to/Xcode-beta.app/Contents/Developer' ./scripts/verify-redesign.sh"
  exit 2
fi

if ! find "$developer_dir" -name 'libSwiftUIMacros.dylib' -print -quit 2>/dev/null | rg -q .; then
  print -u2 "CLI checkpoints passed, but the selected Xcode at $developer_dir does not contain SwiftUIMacros."
  print -u2 "Select a complete Xcode version compatible with the installed macOS SDK."
  exit 2
fi

print "Checkpoint 4/5: release build"
swift build -c release

print "Checkpoint 5/5: tab and adaptive-limit snapshots"
for tab in usage now history settings; do
  SNAPSHOT_TAB="$tab" SNAPSHOT_LIMITS=all \
    .build/release/TokenScope --snapshot "$cache_root/snapshots/$tab-all.png"
done

for limits in three two one none; do
  SNAPSHOT_TAB=usage SNAPSHOT_LIMITS="$limits" \
    .build/release/TokenScope --snapshot "$cache_root/snapshots/usage-$limits.png"
done

print "Verification complete."
print "Snapshots: $cache_root/snapshots"
