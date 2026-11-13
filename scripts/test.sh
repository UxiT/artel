#!/bin/zsh
# Run unit tests with Command Line Tools only (no Xcode): point SwiftPM at the CLT copy of swift-testing.
set -e
cd "$(dirname "$0")/.."
DEV=$(xcode-select -p)
if [[ "$DEV" == *CommandLineTools* ]]; then
  F="$DEV/Library/Developer/Frameworks"; L="$DEV/Library/Developer/usr/lib"
  exec swift test -Xswiftc -F"$F" -Xlinker -F"$F" -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@"
fi
exec swift test "$@"
