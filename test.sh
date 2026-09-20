#!/usr/bin/env bash
#
# test.sh - run the pure-Go unit tests for vugu.
#
# The wasm-test-suite / legacy-wasm-test-suite packages are NOT run here: they
# require a browser (chromedp) and the nginx + wasm dev server, and are normally
# executed via the mage targets or the docker based wasm test runner.
#
# Usage:
#   ./test.sh                 run all pure-Go unit packages
#   ./test.sh ./...           pass explicit "go test" package patterns
#   ./test.sh -run TestBuildEnv .
#
set -euo pipefail

cd "$(dirname "$0")"

# Pure-Go library packages (no browser / wasm server required).
DEFAULT_PKGS=(
	.
	./devutil
	./domrender
	./gen
	./internal/htmlx/...
	./js
	./simplehttp
	./staticrender
	./vugufmt
)

if [ "$#" -gt 0 ]; then
	PKGS=("$@")
else
	PKGS=("${DEFAULT_PKGS[@]}")
fi

echo "==> go test ${PKGS[*]}"
go test -count=1 "${PKGS[@]}"
