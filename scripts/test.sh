#!/usr/bin/env bash
# Builds and tests LoreGraphKit. On a Mac (or anywhere with Swift) it runs `swift test`
# directly; elsewhere it runs in the official Swift image (Docker). Pass --coverage to print the
# line coverage of the package's sources and fail under the threshold (COVERAGE_MIN, default 95).
set -euo pipefail
cd "$(dirname "$0")/.."
COVERAGE=0
ARGS=()
for a in "$@"; do
  if [[ "$a" == "--coverage" ]]; then COVERAGE=1; else ARGS+=("$a"); fi
done
run() {
  if command -v swift >/dev/null 2>&1 && [[ "${USE_DOCKER:-0}" != "1" ]]; then
    "$@"
  else
    docker run --rm -v "$PWD":/src -w /src -e COVERAGE_MIN "${SWIFT_IMAGE:-swift:6.4.1}" "$@"
  fi
}
if [[ $COVERAGE == 1 ]]; then
  run bash scripts/coverage.sh "${ARGS[@]+"${ARGS[@]}"}"
else
  run bash -c 'cd LoreGraphKit && swift test "$@"' _ "${ARGS[@]+"${ARGS[@]}"}"
fi
