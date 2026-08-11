#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
configuration="${CONFIGURATION:-release}"
info_plist="$repo_root/Resources/Info.plist"
icon_source="$repo_root/Resources/AppIcon-1024.png"
output_root="$repo_root/.build/app"
app_bundle="$output_root/Codex Echo.app"
sparkle_framework="$repo_root/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
  print -u2 "CONFIGURATION must be debug or release."
  exit 64
fi

required_files=(
  "$repo_root/Package.swift"
  "$repo_root/Package.resolved"
  "$info_plist"
  "$icon_source"
  "$repo_root/LICENSE"
  "$repo_root/THIRD_PARTY_NOTICES"
)
for required_file in "${required_files[@]}"; do
  if [[ ! -s "$required_file" ]]; then
    print -u2 "Missing build input: $required_file"
    exit 1
  fi
done

/usr/bin/plutil -lint "$info_plist" >/dev/null
/usr/bin/swift build \
  --package-path "$repo_root" \
  --configuration "$configuration" \
  --product CodexEcho
bin_path="$(/usr/bin/swift build \
  --package-path "$repo_root" \
  --configuration "$configuration" \
  --show-bin-path)"

if [[ ! -x "$bin_path/CodexEcho" || ! -d "$sparkle_framework" ]]; then
  print -u2 "SwiftPM did not produce the expected app inputs."
  exit 1
fi

staging_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-echo-app.XXXXXX")"
cleanup() {
  /bin/rm -rf -- "$staging_root"
}
trap cleanup EXIT

staged_app="$staging_root/Codex Echo.app"
contents="$staged_app/Contents"
macos="$contents/MacOS"
resources="$contents/Resources"
frameworks="$contents/Frameworks"
iconset="$staging_root/AppIcon.iconset"
/bin/mkdir -p "$macos" "$resources" "$frameworks" "$iconset"

/bin/cp "$bin_path/CodexEcho" "$macos/CodexEcho"
/bin/chmod 755 "$macos/CodexEcho"
/usr/bin/ditto "$sparkle_framework" "$frameworks/Sparkle.framework"
if ! /usr/bin/otool -l "$macos/CodexEcho" \
  | /usr/bin/grep -F '@executable_path/../Frameworks' >/dev/null
then
  /usr/bin/install_name_tool \
    -add_rpath '@executable_path/../Frameworks' \
    "$macos/CodexEcho"
fi

/bin/cp "$info_plist" "$contents/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Set :CodexEchoUpdatesEnabled false" \
  "$contents/Info.plist"
for key in \
  SUFeedURL \
  SUPublicEDKey \
  SUEnableAutomaticChecks \
  SUAutomaticallyUpdate \
  CodexEchoPublicSourceRepository \
  CodexEchoPublicSourceTag \
  CodexEchoPublicSourceCommit \
  CodexEchoSourceManifestSHA256
do
  /usr/libexec/PlistBuddy \
    -c "Delete :$key" \
    "$contents/Info.plist" >/dev/null 2>&1 || true
done

make_icon() {
  local size="$1"
  local filename="$2"
  /usr/bin/sips \
    -z "$size" "$size" \
    "$icon_source" \
    --out "$iconset/$filename" >/dev/null
}
make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png
/usr/bin/iconutil -c icns "$iconset" -o "$resources/AppIcon.icns"

/bin/cp "$repo_root/LICENSE" "$resources/LICENSE"
/bin/cp "$repo_root/THIRD_PARTY_NOTICES" "$resources/THIRD_PARTY_NOTICES"
/bin/chmod 644 "$resources/LICENSE" "$resources/THIRD_PARTY_NOTICES"

/usr/bin/plutil -lint "$contents/Info.plist" >/dev/null
for key_and_value in \
  'CFBundleExecutable=CodexEcho' \
  'CFBundleIdentifier=app.ohida.codex-echo' \
  'CFBundleIconFile=AppIcon' \
  'CFBundlePackageType=APPL' \
  'LSMinimumSystemVersion=14.0' \
  'LSUIElement=true' \
  'LSMultipleInstancesProhibited=true' \
  'CodexEchoUpdatesEnabled=false'
do
  key="${key_and_value%%=*}"
  expected="${key_and_value#*=}"
  actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$contents/Info.plist")"
  if [[ "$actual" != "$expected" ]]; then
    print -u2 "Built app has unexpected $key: $actual"
    exit 1
  fi
done
for absent_key in \
  SUFeedURL \
  SUPublicEDKey \
  SUEnableAutomaticChecks \
  SUAutomaticallyUpdate \
  CodexEchoPublicSourceRepository \
  CodexEchoPublicSourceTag \
  CodexEchoPublicSourceCommit \
  CodexEchoSourceManifestSHA256
do
  if /usr/libexec/PlistBuddy \
    -c "Print :$absent_key" \
    "$contents/Info.plist" >/dev/null 2>&1
  then
    print -u2 "Built app unexpectedly contains $absent_key."
    exit 1
  fi
done
for bundle_input in \
  "$macos/CodexEcho" \
  "$frameworks/Sparkle.framework" \
  "$resources/AppIcon.icns" \
  "$resources/LICENSE" \
  "$resources/THIRD_PARTY_NOTICES"
do
  if [[ ! -e "$bundle_input" ]]; then
    print -u2 "Built app is missing $bundle_input."
    exit 1
  fi
done
/usr/bin/codesign --force --sign - --timestamp=none "$staged_app"
/usr/bin/codesign --verify --strict --verbose=2 "$staged_app"

/bin/mkdir -p "$output_root"
if [[ -e "$app_bundle" ]]; then
  /bin/rm -rf -- "$app_bundle"
fi
/bin/mv "$staged_app" "$app_bundle"
print "Built $app_bundle"
