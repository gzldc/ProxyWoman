#!/usr/bin/env bash
# Builds an ad-hoc signed ProxyWoman.app and packages one DMG per architecture for GitHub Releases.
# Usage: scripts/make-dmg.sh [--allow-dirty]
# Output: dist/ProxyWoman-<version>-apple-silicon.dmg and dist/ProxyWoman-<version>-intel.dmg,
#         each with a .sha256 file next to it.
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
mkdir -p "$dist"

# Staging lives inside dist/ (git-ignored) and is removed on every exit path.
stage_root="$(mktemp -d "$PWD/$dist/.stage.XXXXXX")"
trap 'rm -rf "$stage_root"' EXIT

# One DMG per architecture: `ditto --arch` keeps only that slice of every binary in the bundle, which
# invalidates the signature, so each thinned app is signed again before packaging.
built=()
for pair in "arm64:apple-silicon" "x86_64:intel"; do
  arch="${pair%%:*}"
  label="${pair#*:}"
  dmg_name="$name-$version-$label.dmg"
  dmg="$dist/$dmg_name"
  rm -f "$dmg" "$dmg.sha256"

  stage_dir="$stage_root/$label"
  mkdir -p "$stage_dir"
  ditto --arch "$arch" "$app" "$stage_dir/$name.app"
  codesign --force --deep -s - "$stage_dir/$name.app"
  while IFS= read -r -d '' binary; do
    if lipo -info "$binary" >/dev/null 2>&1; then
      slices="$(lipo -archs "$binary")"
      [[ "$slices" == "$arch" ]] || { echo "error: $binary has '$slices', expected $arch" >&2; exit 1; }
    fi
  done < <(find "$stage_dir/$name.app/Contents/MacOS" -type f -perm -u+x -print0)
  codesign --verify --deep --strict "$stage_dir/$name.app"
  ln -s /Applications "$stage_dir/Applications"

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
  built+=("$arch $dmg")
done

commit="$(git rev-parse --short HEAD)"
dirty_note=""
if [[ -n "$(git status --porcelain)" ]]; then dirty_note=" (dirty tree)"; fi
echo
echo "Release artifacts"
echo "  version:    $version"
echo "  commit:     $commit$dirty_note"
echo "  signature:  ad-hoc, codesign --verify --deep --strict passed (not notarized)"
for entry in "${built[@]}"; do
  dmg="${entry#* }"
  echo "  ${entry%% *}: $dmg ($(du -h "$dmg" | cut -f1 | tr -d ' '))  sha256 $(cut -d' ' -f1 "$dmg.sha256")"
done
