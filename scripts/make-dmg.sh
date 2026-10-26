#!/usr/bin/env bash
# Builds a universal, ad-hoc signed ProxyWoman.app and packages it as a DMG for GitHub Releases.
# Usage: scripts/make-dmg.sh [--allow-dirty]
# Output: dist/ProxyWoman-<version>-universal.dmg and dist/ProxyWoman-<version>-universal.dmg.sha256
# No Apple Developer account, notarization, sudo or network access is involved.
set -euo pipefail

cd "$(dirname "$0")/.."

name="ProxyWoman"
allow_dirty=0
for argument in "$@"; do
  case "$argument" in
    --allow-dirty) allow_dirty=1 ;;
    *)
      echo "usage: $0 [--allow-dirty]" >&2
      exit 64
      ;;
  esac
done

if [[ "$allow_dirty" -ne 1 ]]; then
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: the working tree has uncommitted changes; commit or stash them, or pass --allow-dirty." >&2
    git status --short >&2
    exit 1
  fi
fi

# Same recipe as the acceptance builds: universal (arm64 + x86_64), warnings are errors.
bash scripts/build-app.sh release -Xswiftc -warnings-as-errors

app="build/$name.app"
plist="$app/Contents/Info.plist"
executable="$app/Contents/MacOS/$name"
[[ -d "$app" ]] || { echo "error: $app was not produced" >&2; exit 1; }

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+)*([-+][0-9A-Za-z.-]+)?$ ]]; then
  echo "error: unexpected CFBundleShortVersionString '$version' in $plist" >&2
  exit 1
fi

# Both slices must be present, and the ad-hoc signature must be intact.
archs="$(lipo -archs "$executable")"
for required_arch in arm64 x86_64; do
  if [[ " $archs " != *" $required_arch "* ]]; then
    echo "error: expected a universal binary (arm64 x86_64), got: $archs" >&2
    exit 1
  fi
done
codesign --verify --deep --strict "$app"

dist="dist"
dmg_name="$name-$version-universal.dmg"
dmg="$dist/$dmg_name"
checksum_file="$dmg.sha256"
mkdir -p "$dist"
rm -f "$dmg" "$checksum_file"

# Staging lives inside dist/ (git-ignored) and is removed on every exit path.
stage_dir="$(mktemp -d "$PWD/$dist/.stage.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
ditto "$app" "$stage_dir/$name.app"
ln -s /Applications "$stage_dir/Applications"
codesign --verify --deep --strict "$stage_dir/$name.app"

hdiutil create \
  -volname "$name $version" \
  -srcfolder "$stage_dir" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$dmg" >/dev/null
hdiutil verify "$dmg" >/dev/null

# Record the checksum with a relative file name so `shasum -a 256 -c` works from the download folder.
(cd "$dist" && shasum -a 256 "$dmg_name" > "$dmg_name.sha256")
(cd "$dist" && shasum -a 256 -c "$dmg_name.sha256" >/dev/null)

size="$(du -h "$dmg" | cut -f1 | tr -d ' ')"
commit="$(git rev-parse --short HEAD)"
dirty_note=""
if [[ -n "$(git status --porcelain)" ]]; then dirty_note=" (dirty tree)"; fi
echo
echo "Release artifact"
echo "  version:    $version"
echo "  commit:     $commit$dirty_note"
echo "  archs:      $archs"
echo "  signature:  ad-hoc, codesign --verify --deep --strict passed (not notarized)"
echo "  dmg:        $dmg ($size)"
echo "  sha256:     $(cut -d' ' -f1 "$checksum_file")"
echo "  checksum:   $checksum_file"
