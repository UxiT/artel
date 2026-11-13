#!/bin/zsh
# Publishes an Artel release on GitHub: Artel-X.Y.Z.dmg for a first install, Artel-X.Y.Z.zip and
# appcast.xml for updates. Installed apps find it through Sparkle: SUFeedURL points at appcast.xml
# of the latest release, the zip next to it is signed with the EdDSA key from the Keychain.
#   scripts/release.sh 0.2.0                   # notes: commit subjects since the previous tag
#   scripts/release.sh 0.2.0 --notes notes.md  # notes from a markdown file
#   scripts/release.sh 0.2.0 --dry-run         # build, pack and sign into build/release/, publish nothing
#
# One-time setup:
#   brew install gh && gh auth login
#   scripts/build-app.sh                                  # fetches Sparkle and its tools
#   .build/artifacts/sparkle/Sparkle/bin/generate_keys    # private key → login Keychain, prints the public key
#   put the public key into SUPublicEDKey in Resources/Info.plist and commit it
#   back up the private key outside the repo: generate_keys -x <file>. Without Developer ID signing
#   a lost key can't be rotated: installed apps would never accept another update.
# SPARKLE_KEY_FILE=<file> signs with an exported key instead of the Keychain (e.g. on CI).
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=UxiT/artel
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin
PLIST=Resources/Info.plist

VERSION="" NOTES="" DRY=0
while (( $# )); do
  case $1 in
    --notes) NOTES=${2:?--notes needs a file}; shift ;;
    --dry-run) DRY=1 ;;
    -*) echo "unknown option: $1" >&2; exit 1 ;;
    *) VERSION=$1 ;;
  esac
  shift
done
fail() { echo "release: $*" >&2; exit 1; }
[[ $VERSION =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail "usage: scripts/release.sh X.Y.Z [--notes file.md] [--dry-run]"
[[ -z $NOTES || -f $NOTES ]] || fail "no such notes file: $NOTES"
TAG=v$VERSION
plist() { /usr/libexec/PlistBuddy -c "$1" $PLIST; }

[[ -n "$(plist 'Print :SUPublicEDKey')" ]] || fail "SUPublicEDKey in $PLIST is empty — see the one-time setup at the top of this script"
CURRENT=$(plist 'Print :CFBundleShortVersionString')
[[ $(printf '%s\n' $CURRENT $VERSION | sort -V | tail -1) == $VERSION ]] || fail "$VERSION is older than the current $CURRENT"
if (( ! DRY )); then
  command -v gh >/dev/null || fail "gh is not installed: brew install gh && gh auth login"
  gh auth status >/dev/null 2>&1 || fail "gh is not logged in: gh auth login"
  [[ -z "$(git status --porcelain)" ]] || fail "the working tree has uncommitted changes"
  git fetch -q --tags origin
  ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "tag $TAG already exists"
fi

# CFBundleVersion doubles as Sparkle's version: keep it equal to the marketing version.
if (( DRY )); then
  BACKUP=$(mktemp)
  cp $PLIST $BACKUP
  trap 'cp $BACKUP $PLIST; rm -f $BACKUP' EXIT
fi
# A line edit, not PlistBuddy: that one rewrites the whole file (key order, comments).
perl -pi -e "s|(<key>CFBundle(?:ShortVersionString\|Version)</key><string>)[^<]*(</string>)|\${1}$VERSION\${2}|" $PLIST
[[ $(plist 'Print :CFBundleShortVersionString') == $VERSION && $(plist 'Print :CFBundleVersion') == $VERSION ]] \
  || fail "couldn't set the version in $PLIST"
if (( ! DRY )) && ! git diff --quiet -- $PLIST; then
  git commit -qm "Artel $VERSION" -- $PLIST
fi

scripts/build-app.sh

OUT=$PWD/build/release/$VERSION
rm -rf $OUT
mkdir -p $OUT
ZIP=$OUT/Artel-$VERSION.zip
ditto -c -k --sequesterRsrc --keepParent build/Artel.app $ZIP

# Same name as the archive: generate_appcast embeds it as the update's release notes.
NOTES_FILE=$OUT/Artel-$VERSION.md
if [[ -n $NOTES ]]; then
  cp $NOTES $NOTES_FILE
elif PREV=$(git describe --tags --abbrev=0 2>/dev/null); then
  git log --no-merges --pretty='- %s' $PREV..HEAD > $NOTES_FILE
else
  echo "Первый релиз Artel." > $NOTES_FILE
fi

KEY_ARGS=()
[[ -n ${SPARKLE_KEY_FILE:-} ]] && KEY_ARGS=(--ed-key-file $SPARKLE_KEY_FILE)
$SPARKLE_BIN/generate_appcast $KEY_ARGS --embed-release-notes \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --link "https://github.com/$REPO" \
  -o $OUT/appcast.xml $OUT
echo "Signed $ZIP and wrote $OUT/appcast.xml"

# DMG for the first install: Artel.app next to a link to /Applications to drag it onto, and how to get
# past Gatekeeper (the app isn't notarized). Updates keep going through the zip; the DMG is made
# after generate_appcast so it isn't listed as a second archive.
DMG=$OUT/Artel-$VERSION.dmg
STAGE=$(mktemp -d)
ditto build/Artel.app $STAGE/Artel.app
ln -s /Applications $STAGE/Applications
textutil -convert rtf -inputencoding UTF-8 Resources/FirstLaunch.html -output "$STAGE/Первый запуск.rtf"
hdiutil create -quiet -volname Artel -srcfolder $STAGE -fs HFS+ -format ULMO $DMG
rm -rf $STAGE
hdiutil verify -quiet $DMG
echo "Packed $DMG"

if (( DRY )); then
  echo "Dry run: nothing published."
  exit 0
fi

git push -q origin HEAD
gh release create $TAG $DMG $ZIP $OUT/appcast.xml --repo $REPO --target "$(git rev-parse HEAD)" \
  --title "Artel $VERSION" --notes-file $NOTES_FILE
git fetch -q --tags origin
echo "Published https://github.com/$REPO/releases/tag/$TAG"
