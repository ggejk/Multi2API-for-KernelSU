#!/bin/sh
# Rebuild the pinned upstream release with Android's bionic DNS resolver.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
REV=6575c623d7fabf43522db48321439eb3fb39c0ed
VERSION=v1.5.1
NDK=${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to the Android NDK directory (r28 or newer)}
NDK=$(CDPATH='' cd -- "$NDK" && pwd)
case "$(uname -s)" in
  Linux) HOST=linux-x86_64 ;;
  Darwin) HOST=darwin-x86_64 ;;
  *) printf '%s\n' 'Use a Linux or macOS build host.' >&2; exit 1 ;;
esac
CC="$NDK/toolchains/llvm/prebuilt/$HOST/bin/aarch64-linux-android28-clang"
[ -x "$CC" ] || { printf 'NDK compiler not found: %s\n' "$CC" >&2; exit 1; }
command -v go >/dev/null || { printf '%s\n' 'Go 1.24 or newer is required.' >&2; exit 1; }

BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT
trap 'exit 1' HUP INT TERM
SRC="$BUILD_DIR/src"
git init -q "$SRC"
git -C "$SRC" fetch -q --depth=1 --no-tags https://github.com/jasonxu114514/opencode2api.git "$REV"
git -C "$SRC" checkout -q --detach "$REV"

mkdir -p "$ROOT/dist"
(
  cd "$SRC"
  GOOS=android GOARCH=arm64 CGO_ENABLED=1 CC="$CC" GOWORK=off GOFLAGS='' \
    go build -mod=readonly -trimpath -tags netcgo -buildmode=pie \
      -ldflags "-s -w -linkmode=external -X main.version=$VERSION" \
      -o "$BUILD_DIR/opencode2api" ./cmd/opencode2api
)
install -m 0755 "$BUILD_DIR/opencode2api" "$ROOT/dist/opencode2api-android-arm64"
git -C "$SRC" archive --format=tar.gz --prefix="opencode2api-$VERSION/" \
  -o "$ROOT/dist/opencode2api-$VERSION-source.tar.gz" "$REV"
printf 'Built %s\n' "$ROOT/dist/opencode2api-android-arm64"
