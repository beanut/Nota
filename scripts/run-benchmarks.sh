#!/bin/sh
# Runs InkKit's benchmarks (Packages/InkKit/Tests/InkKitBenchmarks) in Release on an iPad simulator and
# writes the numbers to OUTPUT_DIR/results.json, with the test log and result bundle beside it.
#
#   scripts/run-benchmarks.sh OUTPUT_DIR ["iPad Pro 13-inch (M5)"]
#
# Then compare against a baseline:
#   scripts/bench-compare.py OUTPUT_DIR/results.json --baseline Packages/InkKit/Benchmarks/baselines/<name>.json
set -eu
cd "$(dirname "$0")/.."

out=${1:?usage: scripts/run-benchmarks.sh OUTPUT_DIR [SIMULATOR_NAME]}
mkdir -p "$out"
out=$(cd "$out" && pwd)
simulator=${2:-$(xcrun simctl list devices available | grep -E "^ +iPad Pro 13-inch" | head -1 \
    | sed -E 's/^ *(.*) \([0-9A-F-]{36}\).*/\1/')}
[ -n "$simulator" ] || { echo "error: no iPad Pro 13-inch simulator; pass one by name" >&2; exit 1; }

rm -rf "$out/results.json" "$out/Benchmarks.xcresult"
echo "Benchmarking on $simulator → $out"
cd Packages/InkKit
# TEST_RUNNER_ variables reach the test process without the prefix.
status=0
TEST_RUNNER_INK_BENCH_RESULTS="$out/results.json" xcodebuild test \
    -scheme InkKit \
    -destination "platform=iOS Simulator,name=$simulator" \
    -configuration Release \
    -only-testing:InkKitBenchmarks/InkBenchmarks \
    -only-testing:InkKitBenchmarks/CanvasBenchmarks \
    -only-testing:InkKitBenchmarks/ObjectLayerBenchmarks \
    -resultBundlePath "$out/Benchmarks.xcresult" \
    -skipPackagePluginValidation \
    ENABLE_TESTABILITY=YES \
    CODE_SIGNING_ALLOWED=NO >"$out/xcodebuild.log" 2>&1 || status=$?
grep -E "^\[inkbench\]|Test Case .*(passed|failed)|error:" "$out/xcodebuild.log" || true
[ -f "$out/results.json" ] || { echo "error: no results written; see $out/xcodebuild.log" >&2; exit 1; }
exit $status
