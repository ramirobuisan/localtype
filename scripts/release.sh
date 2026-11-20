#!/bin/bash
# Publishes a LocalType release on GitHub in one go:
#   bumps VERSION (commit + push on main), builds an ad-hoc-signed, stripped app, checks it carries nothing from
#   this Mac, zips it, and publishes the zip plus its SHA-256 (the in-app updater verifies downloads against it).
# Usage: scripts/release.sh <version> <notes.md>      e.g. scripts/release.sh 0.3.2 notes.md
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "release: $*" >&2; exit 1; }

VERSION="${1:-}"; NOTES="${2:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "give a version like 0.3.2"
[ -f "$NOTES" ] || fail "notes file '$NOTES' not found"
command -v gh >/dev/null || fail "needs the GitHub CLI (gh), logged in"
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || fail "run it on main"
[ -z "$(git status --porcelain)" ] || fail "the working tree has uncommitted changes"
git fetch -q origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main isn't in sync with origin/main"
! gh release view "v$VERSION" >/dev/null 2>&1 || fail "v$VERSION already exists"

if [ "$(cat VERSION)" != "$VERSION" ]; then
  echo "$VERSION" > VERSION
  git commit -q -m "Version $VERSION" VERSION
  git push -q origin main
fi

# Ad hoc signature: a personal certificate's name (often an email address) would ship inside a public download.
SIGN_ID=- ./build.sh
codesign -dv LocalType.app 2>&1 | grep -q "Signature=adhoc" || fail "the build isn't ad hoc signed"
codesign --verify --deep --strict LocalType.app || fail "the signature doesn't verify"
[ "$(defaults read "$PWD/LocalType.app/Contents/Info" CFBundleShortVersionString)" = "$VERSION" ] || fail "built version mismatch"
for s in "$HOME/" "$(git config user.email || true)"; do
  [ -n "$s" ] && grep -rqaF -- "$s" LocalType.app && fail "LocalType.app contains '$s'; not publishing"
done

DIST=.build/dist; mkdir -p "$DIST"
ZIP="$DIST/LocalType-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --keepParent LocalType.app "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
echo "$SHA  LocalType-$VERSION.zip" > "$ZIP.sha256"

BODY=$(mktemp)
{ cat "$NOTES"; printf '\n\nSHA-256 of the zip: `%s`\n' "$SHA"; } > "$BODY"
gh release create "v$VERSION" "$ZIP" "$ZIP.sha256" --target main --title "LocalType $VERSION" --notes-file "$BODY"
rm -f "$BODY"
echo "Published LocalType $VERSION ($SHA)"
