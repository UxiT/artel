#!/bin/zsh
# Builds a self-contained arm64 tmux for the app bundle: static libevent, system ncurses.
# Output: build/vendor/tmux and the licenses of tmux and libevent in build/vendor/licenses/
# (cached; delete build/vendor to rebuild).
set -euo pipefail
cd "$(dirname "$0")/.."

LIBEVENT_VERSION=2.1.12-stable
LIBEVENT_SHA256=92e6de1be9ec176428fd2367677e61ceffc2ee1cb119035037a27d346b0403bb
TMUX_VERSION=3.5a
TMUX_SHA256=16216bd0877170dfcc64157085ba9013610b12b082548c7c9542cc0103198951

OUT=build/vendor/tmux
LICENSES=build/vendor/licenses
[[ -x $OUT && -f $LICENSES/tmux.txt && -f $LICENSES/libevent.txt ]] && { echo "tmux already built: $OUT"; exit 0; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PREFIX=$WORK/prefix
export CFLAGS="-arch arm64 -mmacosx-version-min=14.0 -O2"
export LDFLAGS="-arch arm64 -mmacosx-version-min=14.0"

fetch() {  # url sha256 file
  curl -sSLf -o "$WORK/$3" "$1"
  echo "$2  $WORK/$3" | shasum -a 256 -c - >/dev/null || { echo "checksum mismatch: $3" >&2; exit 1; }
}
fetch "https://github.com/libevent/libevent/releases/download/release-$LIBEVENT_VERSION/libevent-$LIBEVENT_VERSION.tar.gz" $LIBEVENT_SHA256 libevent.tgz
fetch "https://github.com/tmux/tmux/releases/download/$TMUX_VERSION/tmux-$TMUX_VERSION.tar.gz" $TMUX_SHA256 tmux.tgz

mkdir -p "$WORK/src"
tar -xzf "$WORK/libevent.tgz" -C "$WORK/src"
tar -xzf "$WORK/tmux.tgz" -C "$WORK/src"

echo "Building libevent…"
(cd "$WORK/src/libevent-$LIBEVENT_VERSION" &&
  ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-openssl --disable-samples \
    --disable-libevent-regress --disable-debug-mode >/dev/null &&
  make -j"$(sysctl -n hw.ncpu)" >/dev/null && make install >/dev/null)

echo "Building tmux…"
(cd "$WORK/src/tmux-$TMUX_VERSION" &&
  LIBEVENT_CFLAGS="-I$PREFIX/include" LIBEVENT_LIBS="$PREFIX/lib/libevent_core.a" \
  LIBNCURSES_CFLAGS="" LIBNCURSES_LIBS="-lncurses" \
  ./configure --prefix="$PREFIX" --disable-utf8proc >/dev/null &&
  make -j"$(sysctl -n hw.ncpu)" >/dev/null)

mkdir -p "$(dirname $OUT)"
cp "$WORK/src/tmux-$TMUX_VERSION/tmux" "$OUT"
strip "$OUT"
# Shipped inside the app next to the other third-party licenses (see build-app.sh).
mkdir -p $LICENSES
cp "$WORK/src/tmux-$TMUX_VERSION/COPYING" $LICENSES/tmux.txt
cp "$WORK/src/libevent-$LIBEVENT_VERSION/LICENSE" $LICENSES/libevent.txt
echo "Built $OUT"
otool -L "$OUT" | tail -n +2
