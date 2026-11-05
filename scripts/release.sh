#!/bin/sh
# Builds Perch into dist/, zips it and publishes it as a GitHub release, for Ollie (or anyone
# with the repo) to install with scripts/install.sh. The installed copy on this Mac is left
# alone. Usage: ./scripts/release.sh [version]   (default: today's date, e.g. 2026.11.05.1)
set -e
cd "$(dirname "$0")/.."

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "Commit your changes first: a release is built from what is committed." >&2
  exit 1
fi

VERSION="${1:-$(date +%Y.%m.%d)}"
# A second release on the same day gets .2, .3, ...
if [ -z "$1" ]; then
  n=1
  while gh release view "v$VERSION" >/dev/null 2>&1; do n=$((n + 1)); VERSION="$(date +%Y.%m.%d).$n"; done
fi

rm -rf dist && mkdir -p dist
PERCH_APP="$PWD/dist/Perch.app" PERCH_VERSION="$VERSION" taskpolicy -c background ./scripts/build-app.sh
ditto -c -k --keepParent dist/Perch.app dist/Perch.zip

git push origin HEAD
gh release create "v$VERSION" dist/Perch.zip --target "$(git rev-parse HEAD)" \
  --title "Perch $VERSION" --notes "$(git log -1 --format=%s)"
echo "Released Perch $VERSION"
