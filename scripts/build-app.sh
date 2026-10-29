#!/usr/bin/env bash
# Builds the app and assembles an ad-hoc signed build/ProxyWoman.app.
# Usage: scripts/build-app.sh [debug|release] [swift-build-options ...]
#   release (default): universal binary (arm64 + x86_64)
#   debug:             host architecture only, faster
set -euo pipefail

cd "$(dirname "$0")/.."

name="ProxyWoman"
# The stdio helper AI clients launch; it ships next to the app executable (Contents/MacOS).
helper="proxywoman-mcp"
config="${1:-release}"
case "$config" in
  debug|release) ;;
  *)
    echo "usage: $0 [debug|release] [swift-build-options ...]" >&2
    exit 64
    ;;
esac
if [[ $# -gt 0 ]]; then shift; fi

# Multi-arch SwiftPM selects Apple's build backend, which adds dependency diagnostics
# absent from native builds. Build each slice sequentially with the native backend;
# retain every caller option and the same arguments for build and path discovery.
bin_dirs=()
if [[ "$config" == debug ]]; then
  build_args=(--product "$name" "$@")
  helper_args=(--product "$helper" "$@")
  swift build "${build_args[@]}"
  swift build "${helper_args[@]}"
  bin_dirs+=("$(swift build "${build_args[@]}" --show-bin-path)")
else
  for architecture in arm64 x86_64; do
    build_args=(-c release --build-system native --arch "$architecture" --product "$name" "$@")
    helper_args=(-c release --build-system native --arch "$architecture" --product "$helper" "$@")
    swift build "${build_args[@]}"
    swift build "${helper_args[@]}"
    bin_dir="$(swift build "${build_args[@]}" --show-bin-path)"
    if [[ ! -f "$bin_dir/$helper" ]]; then
      echo "Missing helper executable: $bin_dir/$helper" >&2
      exit 1
    fi
    lipo "$bin_dir/$name" -verify_arch "$architecture"
    lipo "$bin_dir/$helper" -verify_arch "$architecture"
    bin_dirs+=("$bin_dir")
  done
fi

for bin_dir in "${bin_dirs[@]}"; do
  if [[ ! -f "$bin_dir/$helper" ]]; then
    echo "Missing helper executable: $bin_dir/$helper" >&2
    exit 1
  fi
done

# Validate production resources for every slice before replacing an existing candidate.
source_resources="Packages/Localization/Sources/Localization/Resources"
shopt -s nullglob
# The language list, and so CFBundleLocalizations, must not depend on the caller's locale. LC_ALL overrides every
# other LC_* variable (LC_COLLATE included), so it is the one set; the list is then also sorted explicitly in byte order.
export LC_ALL=C
language_dirs=()
while IFS= read -r language_dir; do
  [[ -n "$language_dir" ]] && language_dirs+=("$language_dir")
done < <(printf '%s\n' "$source_resources"/*.lproj | LC_ALL=C sort)
if [[ ${#language_dirs[@]} -eq 0 ]]; then
  echo "No production localization resources found in $source_resources" >&2
  exit 1
fi
localizations=""
for language_dir in "${language_dirs[@]}"; do
  language="${language_dir##*/}"
  language="${language%.lproj}"
  if [[ ! -s "$language_dir/Localizable.strings" ]]; then
    echo "Missing localization strings for $language" >&2
    exit 1
  fi
  # Plural rules are optional, but one present must be a non-empty, valid property list.
  if [[ -e "$language_dir/Localizable.stringsdict" ]]; then
    if [[ ! -s "$language_dir/Localizable.stringsdict" ]]; then
      echo "Empty localization plural rules for $language" >&2
      exit 1
    fi
    if ! plutil -lint "$language_dir/Localizable.stringsdict" >/dev/null; then
      echo "Invalid localization plural rules for $language: $language_dir/Localizable.stringsdict" >&2
      exit 1
    fi
  fi
  localizations+="        <string>$language</string>"$'\n'
done
if [[ ! -s "$source_resources/zh-Hans.lproj/Localizable.strings" ]]; then
  echo "Missing development language resources: zh-Hans" >&2
  exit 1
fi
for bin_dir in "${bin_dirs[@]}"; do
  resource_bundle="$bin_dir/${name}_Localization.bundle"
  if [[ ! -d "$resource_bundle" ]]; then
    echo "Missing localization resource bundle: $resource_bundle" >&2
    exit 1
  fi
  # Accept both native flat bundles and macOS Contents/Resources layouts.
  resource_root="$resource_bundle"
  if [[ -d "$resource_bundle/Contents/Resources" ]]; then
    resource_root="$resource_bundle/Contents/Resources"
  fi
  for language_dir in "${language_dirs[@]}"; do
    language="${language_dir##*/}"
    language="${language%.lproj}"
    built_language="$(printf '%s' "$language" | tr '[:upper:]' '[:lower:]')"
    if [[ ! -s "$resource_root/$built_language.lproj/Localizable.strings" &&
          ! -s "$resource_root/$language.lproj/Localizable.strings" ]]; then
      echo "Missing localization strings for $language in $resource_bundle" >&2
      exit 1
    fi
    # Plural rules are optional, but one present in the source must reach the built bundle, non-empty and valid.
    if [[ -e "$language_dir/Localizable.stringsdict" ]]; then
      built_plurals=""
      for candidate in "$resource_root/$built_language.lproj/Localizable.stringsdict" \
                       "$resource_root/$language.lproj/Localizable.stringsdict"; do
        if [[ -f "$candidate" ]]; then built_plurals="$candidate"; break; fi
      done
      if [[ -z "$built_plurals" ]]; then
        echo "Missing localization plural rules for $language in $resource_bundle" >&2
        exit 1
      fi
      if [[ ! -s "$built_plurals" ]] || ! plutil -lint "$built_plurals" >/dev/null; then
        echo "Invalid localization plural rules for $language in $resource_bundle: $built_plurals" >&2
        exit 1
      fi
    fi
  done
done
# Committed icon assets (regenerate with scripts/icon/make-icons.sh): the Dock/Finder icon and the menu bar template image.
icon_resources=(AppIcon.icns menubar-diamond.png menubar-diamond@2x.png)
for icon_resource in "${icon_resources[@]}"; do
  if [[ ! -s "App/Resources/$icon_resource" ]]; then
    echo "Missing icon resource: App/Resources/$icon_resource (run scripts/icon/make-icons.sh)" >&2
    exit 1
  fi
done
resource_bundle="${bin_dirs[0]}/${name}_Localization.bundle"
executable="${bin_dirs[0]}/$name"
helper_executable="${bin_dirs[0]}/$helper"
if [[ "$config" == release ]]; then
  # Staging belongs only to this invocation. Failed compilation or merge leaves the
  # previously verified candidate untouched, including acceptance copies beside it.
  mkdir -p build
  stage_dir="$(mktemp -d "$PWD/build/.universal.XXXXXX")"
  trap 'rm -rf "$stage_dir"' EXIT
  executable="$stage_dir/$name"
  lipo -create "${bin_dirs[0]}/$name" "${bin_dirs[1]}/$name" -output "$executable"
  lipo "$executable" -verify_arch arm64 x86_64
  helper_executable="$stage_dir/$helper"
  lipo -create "${bin_dirs[0]}/$helper" "${bin_dirs[1]}/$helper" -output "$helper_executable"
  lipo "$helper_executable" -verify_arch arm64 x86_64
fi

app="build/$name.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$executable" "$app/Contents/MacOS/$name"
cp "$helper_executable" "$app/Contents/MacOS/$helper"
cp -R "$resource_bundle" "$app/Contents/Resources/Localization.bundle"
for icon_resource in "${icon_resources[@]}"; do
  cp "App/Resources/$icon_resource" "$app/Contents/Resources/$icon_resource"
done

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh-Hans</string>
    <key>CFBundleLocalizations</key>
    <array>
$localizations    </array>
    <key>CFBundleExecutable</key>
    <string>$name</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>dev.pwapp.mac</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$name</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.1</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>com.proxywoman.rules.action-card</string>
            <key>UTTypeDescription</key>
            <string>Rule action card</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$app"
echo "Built $app ($config)"
