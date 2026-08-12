#!/bin/zsh

set -euo pipefail

script_directory="${0:A:h}"
source "$script_directory/build_release.sh"

fail_test() {
  print -u2 -- "$1"
  exit 1
}

if (( $# != 1 )); then
  fail_test "Usage: test_build_release.sh <built-app-bundle>"
fi

verification_app="$(existing_directory "$1" "Built app bundle")"
if [[ ! -x "$verification_app/Contents/MacOS/CodexEcho" \
  || ! -d "$verification_app/Contents/Frameworks/Sparkle.framework" ]]
then
  fail_test "Built app bundle does not contain the release app inputs."
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$verification_app"

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-echo-release-builder.XXXXXX")"
trap '/bin/rm -rf -- "$fixture_root"' EXIT

fixture_app="$fixture_root/Path With Spaces/Codex Echo.app"
framework="$fixture_app/Contents/Frameworks/Sparkle.framework"
framework_version="$framework/Versions/B"
/bin/mkdir -p \
  "$framework_version/XPCServices/Installer.xpc" \
  "$framework_version/XPCServices/Downloader.xpc" \
  "$framework_version/Updater.app"
/usr/bin/touch "$framework_version/Autoupdate"
/bin/ln -s B "$framework/Versions/Current"
resolved_framework_version="$(cd "$framework/Versions/Current" && pwd -P)"

typeset -a recorded_paths=()
typeset -a recorded_entitlements=()
run_codesign() {
  recorded_paths+=("${@[-1]}")
  if [[ " ${(j: :)@} " == *" --preserve-metadata=entitlements "* ]]; then
    recorded_entitlements+=(yes)
  else
    recorded_entitlements+=(no)
  fi
}

sign_app "$fixture_app" "Developer ID Application: Test Identity"

typeset -a expected_paths=(
  "$resolved_framework_version/XPCServices/Installer.xpc"
  "$resolved_framework_version/XPCServices/Downloader.xpc"
  "$resolved_framework_version/Autoupdate"
  "$resolved_framework_version/Updater.app"
  "$framework"
  "$fixture_app"
)

if (( ${#recorded_paths[@]} != ${#expected_paths[@]} )); then
  fail_test "Expected ${#expected_paths[@]} separate signing calls, got ${#recorded_paths[@]}."
fi

for index in {1..${#expected_paths[@]}}; do
  if [[ "${recorded_paths[$index]}" != "${expected_paths[$index]}" ]]; then
    fail_test "Signing path $index was not preserved as one argument."
  fi
done

if [[ "${(j: :)recorded_entitlements}" != "no yes no no no no" ]]; then
  fail_test "Downloader entitlements were not preserved exactly once."
fi

dmg_source="$fixture_root/DMG Source"
/bin/mkdir -p "$dmg_source"
/usr/bin/ditto "$verification_app" "$dmg_source/Codex Echo.app"
/bin/ln -s /Applications "$dmg_source/Applications"

for iteration in {1..3}; do
  dmg_path="$fixture_root/Codex Echo Verification $iteration.dmg"
  create_dmg "$dmg_source" "$dmg_path"
  /usr/bin/hdiutil verify "$dmg_path" >/dev/null
  /bin/rm -f -- "$dmg_path"
done

print -- "Release builder signing-path and DMG tests passed."
