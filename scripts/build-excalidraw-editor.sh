#!/bin/zsh
# Builds the optional Excalidraw download of Artel: the editor and exporter (Resources/ExcalidrawEditor/entry.js,
# React + @excalidraw/excalidraw) as one ES module with Excalidraw's fonts, zipped for a GitHub release.
# The app downloads that zip on demand (ExcalidrawAddon.swift) and checks it against the sha256 compiled in.
#
#   scripts/build-excalidraw-editor.sh            # → build/excalidraw/excalidraw-<version>.zip + its sha256
#
# Needs Bun (https://bun.sh, `brew install oven-sh/bun/bun`) — only here, at release time; the app bundle
# doesn't contain it. After building:
#   1. put the printed version and sha256 into ExcalidrawAddon.swift (`version`, `sha256`);
#   2. publish the zip — never as the latest release: Sparkle's feed is releases/latest/download/appcast.xml,
#      so the newest *Artel* release must stay "Latest" (publish this one before the Artel release that pins it):
#        gh release create excalidraw-<version> build/excalidraw/excalidraw-<version>.zip --latest=false \
#          --title "Excalidraw for Artel <version>" --notes "Optional download used by Artel's documentation."
# Bump BUNDLE_REVISION when only entry.js changes; the package versions live in package.json.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_REVISION=1
SRC=Resources/ExcalidrawEditor
EXCALIDRAW_VERSION=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["dependencies"]["@excalidraw/excalidraw"])' $SRC/package.json)
VERSION="$EXCALIDRAW_VERSION-$BUNDLE_REVISION"
OUT=build/excalidraw
ZIP=$OUT/excalidraw-$VERSION.zip

# Bun's own installer puts it in ~/.bun/bin without touching PATH for non-interactive shells.
[[ -x $HOME/.bun/bin/bun ]] && path+=($HOME/.bun/bin)
command -v bun >/dev/null || { echo "Bun is required: brew install oven-sh/bun/bun" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp $SRC/package.json $SRC/entry.js "$WORK/"
[[ -f $SRC/bun.lock ]] && cp $SRC/bun.lock "$WORK/"
(cd "$WORK" && if [[ -f bun.lock ]]; then bun install --frozen-lockfile; else bun install; fi)
# Keep the lockfile in the repo so the next build resolves the same dependency tree.
cp "$WORK/bun.lock" $SRC/bun.lock

STAGE=$WORK/stage
mkdir -p $STAGE
(cd "$WORK" && NODE_ENV=production bun build entry.js --outdir stage --asset-naming '[name].[ext]' \
  --format esm --target browser --minify --conditions production --define process.env.NODE_ENV='"production"')
# Excalidraw loads its fonts from EXCALIDRAW_ASSET_PATH + fonts/…
ditto "$WORK/node_modules/@excalidraw/excalidraw/dist/prod/fonts" $STAGE/fonts

# Licenses of everything in the bundle (all MIT/ISC/BSD-style; checked here so a GPL-incompatible one stands out).
python3 -I - "$WORK/node_modules" $STAGE/LICENSES.txt <<'PY'
import json, os, sys
root, out = sys.argv[1], sys.argv[2]
lines = []
for dirpath, dirs, files in os.walk(root):
    if 'package.json' in files and os.path.basename(os.path.dirname(dirpath)) in ('node_modules',) or \
       ('package.json' in files and os.path.basename(os.path.dirname(os.path.dirname(dirpath))) == 'node_modules'):
        try:
            pkg = json.load(open(os.path.join(dirpath, 'package.json')))
        except Exception:
            continue
        if 'name' not in pkg or 'version' not in pkg:
            continue
        lic = pkg.get('license')
        if isinstance(lic, dict):
            lic = lic.get('type')
        if not lic and isinstance(pkg.get('licenses'), list) and pkg['licenses']:
            lic = ' OR '.join(str(l.get('type', '')) for l in pkg['licenses'])
        if not lic:
            # No field: read the license file itself.
            for name in os.listdir(dirpath):
                if name.lower().startswith('licen'):
                    text = open(os.path.join(dirpath, name), errors='ignore').read(2000)
                    if 'Permission is hereby granted, free of charge' in text:
                        lic = 'MIT (license file)'
                    break
        lic = lic or 'UNKNOWN'
        lines.append(f"{pkg['name']}@{pkg['version']}: {lic}")
lines = sorted(set(lines))
bad = [l for l in lines if not any(k in l for k in ('MIT', 'ISC', 'BSD', 'Apache-2.0', '0BSD', 'OFL', 'Unlicense', 'CC0', 'Python-2.0', 'BlueOak'))]
open(out, 'w').write("Packages in this bundle and their licenses:\n" + "\n".join(lines) + "\n")
if bad:
    print("Check these licenses before publishing:\n" + "\n".join(bad), file=sys.stderr)
PY

mkdir -p $OUT
rm -f $ZIP
(cd $STAGE && zip -qrX "$OLDPWD/$ZIP" .)
SHA=$(shasum -a 256 $ZIP | cut -d' ' -f1)
echo "Built $ZIP ($(du -h $ZIP | cut -f1))"
echo "version: $VERSION"
echo "sha256:  $SHA"
