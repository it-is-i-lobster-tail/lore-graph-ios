#!/usr/bin/env bash
# Runs LoreGraphKit's tests with code coverage, prints line coverage per source file and fails
# when the total is under COVERAGE_MIN percent (default 95). Works on Linux and macOS.
set -euo pipefail
cd "$(dirname "$0")/../LoreGraphKit"
MIN="${COVERAGE_MIN:-95}"
swift test --enable-code-coverage "$@"
BIN="$(swift build --show-bin-path)"
PROF="$BIN/codecov/default.profdata"
TESTS="$(find "$BIN" -maxdepth 1 -name '*PackageTests.xctest' | head -1)"
if [[ -d "$TESTS" ]]; then
  OBJ="$TESTS/Contents/MacOS/$(basename "$TESTS" .xctest)"   # macOS bundle
else
  OBJ="$TESTS"                                               # Linux executable
fi
if command -v llvm-cov >/dev/null 2>&1; then COV=llvm-cov; else COV="xcrun llvm-cov"; fi
$COV report "$OBJ" -instr-profile="$PROF" -ignore-filename-regex='(\.build|Tests)/' | tee coverage-report.txt
TOTAL="$(awk '/^TOTAL/ { print $10 }' coverage-report.txt | tr -d '%')"
rm -f coverage-report.txt
echo "Line coverage: ${TOTAL}% (minimum ${MIN}%)"
awk -v t="$TOTAL" -v m="$MIN" 'BEGIN { exit (t + 0 >= m + 0) ? 0 : 1 }' || { echo "Coverage is below ${MIN}%."; exit 1; }
