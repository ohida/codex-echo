#!/bin/zsh

set -euo pipefail

script_directory="${0:A:h}"
source "$script_directory/build_release.sh"

fail_test() {
  print -u2 -- "$1"
  exit 1
}

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-echo-release-builder.XXXXXX")"
trap '/bin/rm -rf -- "$fixture_root"' EXIT

app="$fixture_root/Path With Spaces/Codex Echo.app"
framework="$app/Contents/Frameworks/Sparkle.framework"
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

sign_app "$app" "Developer ID Application: Test Identity"

typeset -a expected_paths=(
  "$resolved_framework_version/XPCServices/Installer.xpc"
  "$resolved_framework_version/XPCServices/Downloader.xpc"
  "$resolved_framework_version/Autoupdate"
  "$resolved_framework_version/Updater.app"
  "$framework"
  "$app"
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

print -- "Release builder signing-path test passed."
