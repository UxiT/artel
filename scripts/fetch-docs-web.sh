#!/bin/zsh
# Fetches the JavaScript libraries of the markdown preview (Resources/DocsRenderer) from the npm registry:
# pinned versions, checked by sha256. Output: build/vendor/docs-web/ and their licenses in build/vendor/licenses/
# (cached; delete build/vendor/docs-web to fetch again). All of them are MIT or BSD — GPL-3.0 compatible.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=build/vendor/docs-web
LICENSES=build/vendor/licenses
STAMP=$OUT/.complete-3
[[ -f $STAMP ]] && { echo "docs-web already fetched: $OUT"; exit 0; }

# name | tarball path on registry.npmjs.org | sha256
PACKAGES=(
  "markdown-it|markdown-it/-/markdown-it-15.0.3.tgz|98a7453983ab0e268c17dbd5260bf7190ba46b4cca912327fc1c1a2578e4b56d"
  "markdown-it-container|markdown-it-container/-/markdown-it-container-4.0.0.tgz|d5bd78dd73d50aeedc5855bd33311a20716cf6a215d7bb7d862c337d011e58d0"
  "katex|katex/-/katex-0.19.1.tgz|24da5a599eb2fcede2e270b99a6ff48bca816beecc95feeb84e8cccbd1bb34fd"
  "mermaid|mermaid/-/mermaid-12.3.0.tgz|be0684e8d20bfc874df12c0f04927a5c482f57f2200eec54cca52a4583fd4040"
  "highlight.js|@highlightjs/cdn-assets/-/cdn-assets-11.12.0.tgz|b8a006d30f45afe783072569f3d69c5b60c0e7b9ca28cd474e12f2584e2a3bd9"
  "roughjs|roughjs/-/roughjs-4.6.6.tgz|373873b2c3f1b7ddba878525c774816057c5818029780c7fba081f06018ba78c"
)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
rm -rf "$OUT"
mkdir -p "$OUT/katex/fonts" "$OUT/highlight" "$LICENSES"

for entry in $PACKAGES; do
  IFS='|' read -r name tarball sha <<< "$entry"
  curl -sSLf -o "$WORK/$name.tgz" "https://registry.npmjs.org/$tarball"
  echo "$sha  $WORK/$name.tgz" | shasum -a 256 -c - >/dev/null || { echo "checksum mismatch: $name" >&2; exit 1; }
  mkdir -p "$WORK/$name"
  tar -xzf "$WORK/$name.tgz" -C "$WORK/$name"
  cp "$WORK/$name/package/LICENSE" "$LICENSES/$name.txt"
done

P=$WORK
cp "$P/markdown-it/package/dist/browser/markdown-it.umd.min.js" "$OUT/markdown-it.min.js"
cp "$P/markdown-it-container/package/dist/markdown-it-container.min.js" "$OUT/markdown-it-container.min.js"
cp "$P/katex/package/dist/katex.min.js" "$P/katex/package/dist/katex.min.css" "$OUT/katex/"
cp "$P"/katex/package/dist/fonts/*.woff2 "$OUT/katex/fonts/"
cp "$P/mermaid/package/dist/mermaid.min.js" "$OUT/mermaid.min.js"
cp "$P/highlight.js/package/highlight.min.js" "$OUT/highlight/"
cp "$P/highlight.js/package/styles/github.min.css" "$P/highlight.js/package/styles/github-dark.min.css" "$OUT/highlight/"
cp "$P/roughjs/package/bundled/rough.js" "$OUT/rough.js"
touch "$STAMP"
echo "Fetched $OUT ($(du -sh $OUT | cut -f1))"
