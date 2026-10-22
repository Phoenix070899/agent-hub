#!/bin/sh
# Builds libghostty, which draws Echo's terminals, from a pinned Ghostty commit with ghostty.patch
# applied, into Vendor/GhosttyKit. Needs Zig (brew install zig) and network on the first run.
set -eu

COMMIT=67edd20a0292629da7e01b64973de19d356df487
ZIG_VERSION=0.17.0

here=$(cd "$(dirname "$0")" && pwd)
app=$(dirname "$here")
out="$app/Vendor/GhosttyKit"
src="$app/.build/ghostty-src"
stamp="$COMMIT $(shasum -a 256 "$here/ghostty.patch" | cut -d' ' -f1)"

if [ -f "$out/lib/libghostty.a" ] && [ "$(cat "$out/.stamp" 2>/dev/null)" = "$stamp" ]; then
    exit 0
fi

zig=$(command -v zig || echo /opt/homebrew/bin/zig)
if ! [ -x "$zig" ] || [ "$("$zig" version)" != "$ZIG_VERSION" ]; then
    echo "libghostty needs Zig $ZIG_VERSION: brew install zig" >&2
    exit 1
fi

if ! [ -d "$src/.git" ]; then
    mkdir -p "$(dirname "$src")"
    git clone --quiet https://github.com/ghostty-org/ghostty.git "$src"
fi
git -C "$src" fetch --quiet origin "$COMMIT" 2>/dev/null || true
git -C "$src" checkout --quiet --force "$COMMIT"
git -C "$src" clean --quiet -fd
git -C "$src" apply "$here/ghostty.patch"

# The Metal shaders compile at run time (see ghostty.patch), so no Xcode is needed.
(cd "$src" && "$zig" build -Doptimize=ReleaseFast -Demit-xcframework=false -Demit-macos-app=false \
    -Demit-docs=false -Di18n=false --prefix "$src/zig-out")

rm -rf "$out"
mkdir -p "$out/lib" "$out/include"
cp "$src/zig-out/lib/libghostty.a" "$out/lib/"
cp "$src/zig-out/include/ghostty.h" "$out/include/"
cp "$here/module.modulemap" "$out/include/"
echo "$stamp" > "$out/.stamp"
echo "Built $out"
