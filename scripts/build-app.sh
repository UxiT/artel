#!/bin/zsh
# Builds Artel.app (arm64) with SwiftPM only — no Xcode required.
#   scripts/build-app.sh            # release build into build/Artel.app
#   scripts/build-app.sh debug      # debug build
#   scripts/build-app.sh --install  # also copy to /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
INSTALL=0
for arg in "$@"; do
  case $arg in
    debug) CONFIG=debug ;;
    --install) INSTALL=1 ;;
  esac
done

scripts/build-tmux.sh   # cached in build/vendor/tmux
scripts/fetch-docs-web.sh   # markdown preview libraries, cached in build/vendor/docs-web
swift build -c "$CONFIG" --arch arm64 --product Artel
swift build -c "$CONFIG" --arch arm64 --product artel-hook
BIN=$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)

APP=build/Artel.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Artel" "$BIN/artel-hook" "$APP/Contents/MacOS/"
if [[ $CONFIG == release ]]; then
  # The debug map and local symbols hold absolute paths of the build machine (/Users/<name>/…):
  # drop them from shipped binaries. The linker's signature goes first (re-signed below) so strip
  # doesn't warn about invalidating it.
  for exe in "$APP/Contents/MacOS/Artel" "$APP/Contents/MacOS/artel-hook"; do
    codesign --remove-signature "$exe"
    strip -S -x "$exe"
  done
fi
cp build/vendor/tmux "$APP/Contents/MacOS/tmux"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Sparkle (self-update) comes from SwiftPM as a prebuilt, already signed framework.
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Artel"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Markdown preview: Artel's renderer page plus the fetched libraries under vendor/.
ditto Resources/DocsRenderer "$APP/Contents/Resources/DocsRenderer"
ditto build/vendor/docs-web "$APP/Contents/Resources/DocsRenderer/vendor"
rm -f "$APP/Contents/Resources/DocsRenderer/vendor/.complete-"*
# SwiftPM resource bundles of dependencies, if any.
for b in "$BIN"/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done
# Licenses: Artel's own (GPL-3.0) and those of everything bundled in the app.
LIC="$APP/Contents/Resources/Licenses"
rm -rf "$LIC"
mkdir -p "$LIC"
cp LICENSE "$LIC/Artel.txt"
# Only packages pinned in Package.resolved: .build/checkouts keeps dependencies that were removed.
for loc in ${(f)"$(sed -n 's/.*"location" : "\(.*\)".*/\1/p' Package.resolved)"}; do
  name=${${loc:t}%.git}
  dir=.build/checkouts/$name
  [[ -d $dir ]] || { echo "no checkout for $name" >&2; exit 1; }
  for f in $dir/(LICENSE|COPYING)*(N.); do cp "$f" "$LIC/$name.txt"; break; done
done
cp build/vendor/licenses/*.txt "$LIC/"

# Ad-hoc signature: enough to run locally and to use notifications.
codesign --force --sign - "$APP/Contents/MacOS/artel-hook"
codesign --force --sign - "$APP/Contents/MacOS/tmux"
codesign --force --sign - "$APP"
echo "Built $APP"

if (( INSTALL )); then
  rm -rf /Applications/Artel.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/Artel.app"
fi
