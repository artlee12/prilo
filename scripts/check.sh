#!/bin/bash
# Runs every static check and test suite. Use before building a release.
set -euo pipefail

cd "$(dirname "$0")/.."
section() { printf '\n== %s ==\n' "$1"; }

section "Windows receiver: vet (windows) + tests (host)"
(
    cd windows
    unformatted="$(gofmt -l .)"
    if [ -n "$unformatted" ]; then echo "gofmt needed: $unformatted"; exit 1; fi
    GOOS=windows GOARCH=amd64 go vet ./...
    go vet ./...
    go test -race -count=1 ./...
)

section "Mac app: typecheck + logic tests"
cache="$(mktemp -d "${TMPDIR:-/tmp}/prilo-check.XXXXXX")"
trap 'rm -rf "$cache"' EXIT
sdk="${SDKROOT:-$(xcrun --show-sdk-path)}"
if [ -z "${SDKROOT:-}" ]; then
    dev_dir="$(xcode-select -p 2>/dev/null || true)"
    if [ "$dev_dir" = "/Library/Developer/CommandLineTools" ] \
        && [ ! -e "$dev_dir/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ] \
        && [ -d "$dev_dir/SDKs/MacOSX26.sdk" ]; then
        sdk="$dev_dir/SDKs/MacOSX26.sdk"
    fi
fi
swiftc -swift-version 5 -typecheck -sdk "$sdk" -target arm64-apple-macos14.0 -module-cache-path "$cache" mac/*.swift
scripts/test-mac.sh

section "Homebridge plugin"
if command -v node >/dev/null 2>&1; then
    (cd homebridge && node --test)
else
    echo "node not found, skipped"
fi

section "Shell scripts"
bash -n build.sh scripts/*.sh

printf '\nAll checks passed.\n'
