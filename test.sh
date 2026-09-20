#!/usr/bin/env bash
#
# test.sh - manually run the vugu Go unit tests.
#
# Unit-testable packages are run by default. The wasm-test-suite and
# legacy-wasm-test-suite directories require a headless Chrome / Docker
# environment (see wasm-test-suite/docker) and are therefore skipped unless
# --wasm is passed and the browser environment is available.
#
# Usage:
#   ./test.sh                 # run unit tests (normal environment)
#   ./test.sh . ./gen         # run only the listed packages
#   ./test.sh --offline       # offline mode: uses local stubs when the
#                             # github.com/vugu/* modules are not cached
#   ./test.sh --net           # also run tests that bind local TCP ports
#                             # (e.g. simplehttp; skipped otherwise in sandboxes)
#   ./test.sh --wasm          # additionally run the wasm test suites
#   ./test.sh -v -run X       # extra flags after a "--" are passed to go test
#
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

OFFLINE=0
RUN_WASM=0
RUN_NET=0
PACKAGES=()
GO_TEST_ARGS=()

while [[ $# -gt 0 ]]; do
	case "$1" in
	--offline)
		OFFLINE=1
		shift
		;;
	--wasm)
		RUN_WASM=1
		shift
		;;
	--net)
		RUN_NET=1
		shift
		;;
	--help|-h)
		sed -n '2,22p' "$0"
		exit 0
		;;
	--)
		shift
		GO_TEST_ARGS+=("$@")
		break
		;;
	-*)
		GO_TEST_ARGS+=("$1")
		shift
		;;
	*)
		PACKAGES+=("$1")
		shift
		;;
	esac
done

# packages that contain pure-Go unit tests and do not require a browser
DEFAULT_PACKAGES=(
	.
	./devutil
	./distutil
	./domrender
	./gen
	./js
	./staticrender
	./vgform
)

# tests that must bind a local TCP port (blocked in some sandboxes)
NET_PACKAGES=(
	./simplehttp
)

if [[ ${#PACKAGES[@]} -eq 0 ]]; then
	PACKAGES=("${DEFAULT_PACKAGES[@]}")
	if [[ "$RUN_NET" -eq 1 ]]; then
		PACKAGES+=("${NET_PACKAGES[@]}")
	fi
else
	# explicitly named packages are always run, even without --net
	RUN_NET=1
fi

# keep the Go build cache out of the system cache (works in restricted sandboxes too)
export GOCACHE="${GOCACHE:-${TMPDIR:-/tmp}/vugu-gocache}"
mkdir -p "$GOCACHE"

MODFILE_FLAG=()
STUB_DIR=""
OFFLINE_MODFILE=""

cleanup() {
	if [[ -n "$OFFLINE_MODFILE" && -f "$OFFLINE_MODFILE" ]]; then
		rm -f "$OFFLINE_MODFILE" "${OFFLINE_MODFILE%.mod}.sum"
	fi
	if [[ -n "$STUB_DIR" && -d "$STUB_DIR" ]]; then
		rm -rf "$STUB_DIR"
	fi
}
trap cleanup EXIT

# Decide whether the github.com/vugu support modules are available.
# When they are not (no network / empty module cache), build minimal local
# stubs and an alternate go.mod so the tests can still be run offline.
setup_offline() {
	echo "[test.sh] offline mode: preparing local stubs for github.com/vugu modules"
	STUB_DIR="$(mktemp -d /private/tmp/vugu-stubs.XXXXXX)"

	mkdir -p "$STUB_DIR/xxhash"
	cat >"$STUB_DIR/xxhash/go.mod" <<'GOMOD'
module github.com/vugu/xxhash

go 1.22
GOMOD
	cat >"$STUB_DIR/xxhash/xxhash.go" <<'GOFILE'
// Package xxhash is a minimal offline test stub providing the subset of the
// real github.com/vugu/xxhash API used by vugu (New/Write/Sum64).
package xxhash

import "hash/fnv"

// Digest implements the subset of hash.Hash64 used by vugu.
type Digest struct {
	h interface {
		Write([]byte) (int, error)
		Sum64() uint64
	}
}

// New returns a 64-bit non-cryptographic hasher.
func New() *Digest {
	return &Digest{h: fnv.New64a()}
}

// Write adds bytes to the hash.
func (d *Digest) Write(p []byte) (int, error) { return d.h.Write(p) }

// WriteString adds a string to the hash.
func (d *Digest) WriteString(s string) (int, error) { return d.h.Write([]byte(s)) }

// Sum64 returns the current hash value.
func (d *Digest) Sum64() uint64 { return d.h.Sum64() }
GOFILE

	mkdir -p "$STUB_DIR/vjson"
	cat >"$STUB_DIR/vjson/go.mod" <<'GOMOD'
module github.com/vugu/vjson

go 1.22
GOMOD
	# vjson is a fork of encoding/json with the same exported surface
	cat >"$STUB_DIR/vjson/vjson.go" <<'GOFILE'
// Package vjson is an offline test stub aliasing encoding/json.
package vjson

import "encoding/json"

type (
	RawMessage  = json.RawMessage
	Marshaler   = json.Marshaler
	Unmarshaler = json.Unmarshaler
	Decoder     = json.Decoder
	Encoder     = json.Encoder
)

var Marshal = json.Marshal
var Unmarshal = json.Unmarshal
var NewDecoder = json.NewDecoder
var NewEncoder = json.NewEncoder
GOFILE

	# github.com/vugu/html is a fork of golang.org/x/net/html; vendor the
	# cached copy (non-test files) and rewrite the import paths
	# pick the newest cached x/net that is old enough not to require go 1.23 iterators
	XNET_DIR=""
	for cand in $(ls -d "$(go env GOMODCACHE)"/golang.org/x/net@v0.2*/html 2>/dev/null | sort -V -r); do
		if [[ ! -f "$cand/iter.go" ]]; then
			XNET_DIR="$cand"
			break
		fi
	done
	if [[ -z "$XNET_DIR" ]]; then
		XNET_DIR="$(go list -f '{{.Dir}}' golang.org/x/net/html 2>/dev/null || true)"
	fi
	if [[ ! -d "$XNET_DIR" ]]; then
		echo "[test.sh] WARNING: golang.org/x/net/html sources not found; packages depending on vugu/html may fail offline" >&2
	else
		mkdir -p "$STUB_DIR/html/atom"
		cat >"$STUB_DIR/html/go.mod" <<'GOMOD'
module github.com/vugu/html

go 1.22
GOMOD
		for f in "$XNET_DIR"/*.go; do
			[[ "$(basename "$f")" == *_test.go ]] && continue
			[[ "$(basename "$f")" == "iter.go" ]] && continue
			sed 's#golang.org/x/net/html/atom#github.com/vugu/html/atom#g; s#// import "golang.org/x/net/html"##g' "$f" >"$STUB_DIR/html/$(basename "$f")"
		done
		for f in "$XNET_DIR"/atom/*.go; do
			[[ "$(basename "$f")" == *_test.go ]] && continue
			cp "$f" "$STUB_DIR/html/atom/$(basename "$f")"
		done

		# The real github.com/vugu/html fork preserves the original-case tag
		# name (Node.OrigData) and attribute key (Attribute.OrigKey). Add those
		# fields to the vendored structs and populate them after parsing.
		token_go="$STUB_DIR/html/token.go"
		node_go="$STUB_DIR/html/node.go"
		sed -i '' 's#^	Namespace, Key, Val string$#	Namespace, Key, Val string\
	OrigKey string // vugu fork: original-case key#' "$token_go"
		# keep the existing positional struct literal compiling
		sed -i '' 's#t.Attr = append(t.Attr, Attribute{"", atom.String(key), string(val)})#t.Attr = append(t.Attr, Attribute{"", atom.String(key), string(val), atom.String(key)})#' "$token_go"
		sed -i '' 's#^	Data      string$#	Data      string\
	OrigData string // vugu fork: original-case tag name#' "$node_go"

		# replace Parse/ParseFragment with fork wrappers that additionally
		# populate the OrigData/OrigKey fields
		parse_go="$STUB_DIR/html/parse.go"
		sed -i '' '/^func Parse(r io.Reader) (\*Node, error) {$/,/^}$/d; /^func ParseFragment(r io.Reader, context \*Node) (\[\]\*Node, error) {$/,/^}$/d' "$parse_go"

		cat >"$STUB_DIR/html/vugu_fork.go" <<'GOFILE'
package html

import "io"

// populateOrig walks the parsed tree and fills in the fork-only OrigData /
// OrigKey fields with the original-case strings from the source document.
func populateOrig(n *Node) {
	if n == nil {
		return
	}
	if n.Type == ElementNode {
		n.OrigData = n.Data
	}
	for i := range n.Attr {
		n.Attr[i].OrigKey = n.Attr[i].Key
	}
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		populateOrig(c)
	}
}

// Parse behaves like the standard parser but additionally sets OrigData/OrigKey.
func Parse(r io.Reader) (*Node, error) {
	n, err := ParseWithOptions(r)
	if err != nil {
		return nil, err
	}
	populateOrig(n)
	return n, nil
}

// ParseFragment behaves like the standard fragment parser but additionally
// sets OrigData/OrigKey.
func ParseFragment(r io.Reader, context *Node) ([]*Node, error) {
	nl, err := ParseFragmentWithOptions(r, context)
	if err != nil {
		return nil, err
	}
	for _, n := range nl {
		populateOrig(n)
	}
	return nl, nil
}
GOFILE

		sed -i '' 's#package atom // import "golang.org/x/net/html/atom"#package atom#' "$STUB_DIR/html/atom/"*.go 2>/dev/null || true
	fi

	# golang.org/x/text stub: only the cases/language surface used by vgform
	if [[ -z "$(ls -d "$(go env GOMODCACHE)"/golang.org/x/text@v0.17.0 2>/dev/null)" ]]; then
		mkdir -p "$STUB_DIR/xtext/cases" "$STUB_DIR/xtext/language"
		cat >"$STUB_DIR/xtext/go.mod" <<'GOMOD'
module golang.org/x/text

go 1.22
GOMOD
		cat >"$STUB_DIR/xtext/cases/cases.go" <<'GOFILE'
// Package cases is an offline test stub providing a title-casing Caser.
package cases

import (
	"strings"
	"unicode"
)

// Caser mimics golang.org/x/text/cases.Caser for the methods vugu uses.
type Caser struct{}

// Title returns a title-casing Caser; the language argument is ignored.
func Title(_ interface{}) Caser { return Caser{} }

// String returns s with each word title cased.
func (Caser) String(s string) string {
	prevSpace := true
	return strings.Map(func(r rune) rune {
		if unicode.IsSpace(r) {
			prevSpace = true
			return r
		}
		if prevSpace {
			prevSpace = false
			return unicode.ToTitle(r)
		}
		return r
	}, s)
}

// Bytes is provided for interface parity.
func (c Caser) Bytes(b []byte) []byte { return []byte(c.String(string(b))) }
GOFILE
		cat >"$STUB_DIR/xtext/language/language.go" <<'GOFILE'
// Package language is an offline test stub for golang.org/x/text/language.
package language

// Tag stands in for language.Tag.
type Tag struct{}

// Und stands in for language.Und.
var Und Tag
GOFILE
	fi

	OFFLINE_MODFILE="$ROOT_DIR/go.offline-test.mod"
	cp go.mod "$OFFLINE_MODFILE"
	cp go.sum "${OFFLINE_MODFILE%.mod}.sum"
	{
		echo ""
		echo "replace github.com/vugu/xxhash => $STUB_DIR/xxhash"
		echo "replace github.com/vugu/vjson => $STUB_DIR/vjson"
		echo "replace github.com/vugu/html => $STUB_DIR/html"
		if [[ -d "$STUB_DIR/xtext" ]]; then echo "replace golang.org/x/text => $STUB_DIR/xtext"; fi
	} >>"$OFFLINE_MODFILE"

	export GOPROXY=off
	export GOFLAGS=-mod=mod
	MODFILE_FLAG=(-modfile="$OFFLINE_MODFILE")
}

if [[ "$OFFLINE" -eq 1 ]]; then
	setup_offline
else
	# auto-detect: if the required vugu module cannot be resolved, switch to offline
	if ! GOCACHE="$GOCACHE" go list -m github.com/vugu/xxhash >/dev/null 2>&1; then
		setup_offline
	fi
fi

echo "[test.sh] packages: ${PACKAGES[*]}"
echo "[test.sh] go test ${MODFILE_FLAG[*]:-} ${GO_TEST_ARGS[*]:-} (offline stubs in use: $([[ ${#MODFILE_FLAG[@]} -gt 0 ]] && echo yes || echo no))"

fail=0
for pkg in "${PACKAGES[@]}"; do
	echo ""
	echo "===== go test $pkg ====="
	if ! go test ${MODFILE_FLAG[@]+"${MODFILE_FLAG[@]}"} -count=1 ${GO_TEST_ARGS[@]+"${GO_TEST_ARGS[@]}"} "$pkg"; then
		echo "[test.sh] FAILED: $pkg"
		fail=1
	fi
done

# The wasm test suites each have their own go.mod and need Chrome via Docker;
# they are intentionally separate and only run on explicit request.
if [[ "$RUN_WASM" -eq 1 ]]; then
	for suite in wasm-test-suite legacy-wasm-test-suite; do
		while IFS= read -r dir; do
			echo ""
			echo "===== wasm suite: $dir ====="
			( cd "$dir" && go test -count=1 ${GO_TEST_ARGS[@]+"${GO_TEST_ARGS[@]}"} ./... ) || fail=1
		done < <(find "$suite" -mindepth 1 -maxdepth 1 -type d | sort)
	done
fi

if [[ "$fail" -ne 0 ]]; then
	echo ""
	echo "[test.sh] some packages FAILED"
	exit 1
fi

echo ""
echo "[test.sh] all unit tests passed"
