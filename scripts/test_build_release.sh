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

release_version="$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleShortVersionString' \
  "$verification_app/Contents/Info.plist")"
release_notes="$script_directory/../release-notes/$release_version.md"
validate_release_notes_file "$release_notes"

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-echo-release-builder.XXXXXX")"
trap '/bin/rm -rf -- "$fixture_root"' EXIT

source_root="$script_directory/.."
source_fixture="$fixture_root/Source Package"
/bin/mkdir -p "$source_fixture/Resources" "$source_fixture/release-notes"
for file in Package.swift Package.resolved LICENSE THIRD_PARTY_NOTICES; do
  /bin/cp "$source_root/$file" "$source_fixture/$file"
done
/bin/cp "$source_root/Resources/Info.plist" "$source_fixture/Resources/Info.plist"
/bin/cp "$source_root/Resources/AppIcon-1024.png" \
  "$source_fixture/Resources/AppIcon-1024.png"
/bin/cp "$release_notes" "$source_fixture/release-notes/$release_version.md"

RELEASE_VERSION="$release_version"
RELEASE_BUILD="$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleVersion' \
  "$source_fixture/Resources/Info.plist")"
RELEASE_TAG="v$RELEASE_VERSION-build.$RELEASE_BUILD"
validate_source_package "$source_fixture"

expect_source_package_rejected() {
  local label="$1"
  local expected_error="$2"
  local error_file="$fixture_root/source-package-error.txt"
  if (validate_source_package "$source_fixture") > /dev/null 2> "$error_file"; then
    fail_test "$label passed source-package validation."
  fi
  if [[ "$(<"$error_file")" != *"$expected_error"* ]]; then
    fail_test "$label failed for an unexpected reason: $(<"$error_file")"
  fi
}

/usr/bin/sed \
  's/\.executable(name: "CodexEcho", targets: \["CodexEcho"\])/\.executable(name: "CodexEcho", targets: ["CodexEcho"]), .library(name: "CodexEchoInternals", targets: ["CodexIPC"])/' \
  "$source_root/Package.swift" > "$source_fixture/Package.swift"
if /usr/bin/cmp -s "$source_root/Package.swift" "$source_fixture/Package.swift"; then
  fail_test "Could not create extra-library source-package fixture."
fi
expect_source_package_rejected \
  "Extra library product" \
  "The public package must expose only the CodexEcho executable."

/usr/bin/sed 's/exact: "0.12.1"/exact: "0.12.2"/' \
  "$source_root/Package.swift" > "$source_fixture/Package.swift"
if /usr/bin/cmp -s "$source_root/Package.swift" "$source_fixture/Package.swift"; then
  fail_test "Could not create MCP version source-package fixture."
fi
expect_source_package_rejected \
  "MCP SDK version mismatch" \
  "The public package must expose only the CodexEcho executable."
/bin/cp "$source_root/Package.swift" "$source_fixture/Package.swift"

/usr/bin/jq '.pins[-1] = .pins[0]' "$source_root/Package.resolved" \
  > "$source_fixture/Package.resolved"
expect_source_package_rejected \
  "Duplicate pin replacing a required identity" \
  "Package.resolved does not contain the reviewed dependency pins."

/usr/bin/jq \
  '(.pins[] | select(.identity == "swift-sdk").state.revision) = "0000000000000000000000000000000000000000"' \
  "$source_root/Package.resolved" > "$source_fixture/Package.resolved"
expect_source_package_rejected \
  "MCP SDK revision mismatch" \
  "Package.resolved does not contain the reviewed dependency pins."

/usr/bin/jq 'del(.pins[] | select(.identity == "swift-nio-http2"))' \
  "$source_root/Package.resolved" > "$source_fixture/Package.resolved"
expect_source_package_rejected \
  "Missing optional dependency pin" \
  "Package.resolved does not contain the reviewed dependency pins."

/usr/bin/jq \
  '(.pins[] | select(.identity == "swift-nio-http2").state.revision) = "0000000000000000000000000000000000000000"' \
  "$source_root/Package.resolved" > "$source_fixture/Package.resolved"
expect_source_package_rejected \
  "Optional dependency revision mismatch" \
  "Package.resolved does not contain the reviewed dependency pins."

/usr/bin/jq \
  '.pins += [{identity: "unreviewed-package", kind: "remoteSourceControl", location: "https://example.invalid/unreviewed-package.git", state: {revision: "0000000000000000000000000000000000000000", version: "1.0.0"}}]' \
  "$source_root/Package.resolved" > "$source_fixture/Package.resolved"
expect_source_package_rejected \
  "Extra unreviewed dependency pin" \
  "Package.resolved does not contain the reviewed dependency pins."

/usr/bin/jq \
  '(.pins[] | select(.identity == "swift-nio-http2")).identity = "unreviewed-package"' \
  "$source_root/Package.resolved" > "$source_fixture/Package.resolved"
expect_source_package_rejected \
  "Unreviewed pin replacing an optional dependency" \
  "Package.resolved does not contain the reviewed dependency pins."

expect_build_lock_rewrite_rejected() {
  local mutation_call="$1"
  local payload="$fixture_root/Payload After Build $mutation_call"
  local error_file="$fixture_root/source-build-error-$mutation_call.txt"
  local calls_file="$fixture_root/source-build-calls-$mutation_call.txt"
  local reviewed_lock="$source_root/Package.resolved"
  /bin/cp "$reviewed_lock" "$source_fixture/Package.resolved"
  if (
    SOURCE_REPOSITORY="ohida/codex-echo"
    SOURCE_REF="refs/tags/$RELEASE_TAG"
    SOURCE_COMMIT="0123456789abcdef0123456789abcdef01234567"
    BUILDER_COMMIT="89abcdef0123456789abcdef0123456789abcdef"
    typeset -i build_calls=0
    run_swift_build() {
      if [[ " $* " != *" --force-resolved-versions "* ]]; then
        fail_test "Swift build must use the reviewed resolved versions."
      fi
      build_calls=$((build_calls + 1))
      print -r -- "$build_calls" >> "$calls_file"
      if (( build_calls == mutation_call )); then
        /usr/bin/jq \
          '(.pins[] | select(.identity == "swift-nio-http2").state.revision) = "0000000000000000000000000000000000000000"' \
          "$reviewed_lock" > "$source_fixture/Package.resolved"
      fi
      if [[ " $* " == *" --show-bin-path "* ]]; then
        print -r -- "$fixture_root/Unused Bin Path"
      fi
    }
    prepare_source "$source_fixture" "$payload"
  ) > /dev/null 2> "$error_file"; then
    fail_test "Build call $mutation_call changed the lock and produced a payload."
  fi
  if [[ "$(<"$error_file")" \
    != *"Package.resolved does not contain the reviewed dependency pins."* ]]
  then
    fail_test "Build call $mutation_call failed for an unexpected reason: $(<"$error_file")"
  fi
  if [[ "$(<"$calls_file")" != $'1\n2' ]]; then
    fail_test "Expected two forced Swift build calls before lock revalidation."
  fi
  if [[ -e "$payload/identity.json" \
    || -n "$(/usr/bin/find "$payload" -mindepth 1 -print -quit)" ]]
  then
    fail_test "Build call $mutation_call left source payload files after lock rewrite."
  fi
}
expect_build_lock_rewrite_rejected 1
expect_build_lock_rewrite_rejected 2
print -- "Release builder source-package allowlist tests passed."

appcast_fixture="$fixture_root/appcast.xml"
history_fixture="https://github.com/ohida/codex-echo/releases/tag/v$release_version-build.1"
{
  print -r -- '<?xml version="1.0" encoding="utf-8"?>'
  print -r -- '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><item>'
  print -rn -- '<description sparkle:format="markdown"><![CDATA['
  /bin/cat "$release_notes"
  print -r -- ']]></description>'
  print -r -- "<sparkle:fullReleaseNotesLink>$history_fixture</sparkle:fullReleaseNotesLink>"
  print -r -- '</item></channel></rss>'
} > "$appcast_fixture"
verify_appcast_release_notes "$appcast_fixture" "$release_notes" "$history_fixture"

missing_notes_fixture="$fixture_root/appcast-without-notes.xml"
print -r -- \
  '<?xml version="1.0"?><rss><channel><item></item></channel></rss>' \
  > "$missing_notes_fixture"
if (verify_appcast_release_notes \
  "$missing_notes_fixture" "$release_notes" "$history_fixture") 2>/dev/null
then
  fail_test "Appcast without embedded release notes passed verification."
fi

url_fixture_commit="0123456789abcdef0123456789abcdef01234567"
expected_url_prefix="$immutable_download_root/$url_fixture_commit/"
actual_url_prefix="$(sparkle_download_url_prefix "$url_fixture_commit")"
if [[ "$actual_url_prefix" != "$expected_url_prefix" ]]
then
  fail_test "Sparkle download URL prefix must preserve the source commit path."
fi
url_fixture_archive="Codex-Echo-URL-Fixture.zip"
resolved_archive_url="$(
  SPARKLE_URL_PREFIX="$actual_url_prefix" \
  SPARKLE_ARCHIVE_NAME="$url_fixture_archive" \
    /usr/bin/swift -e '
      import Foundation

      let environment = ProcessInfo.processInfo.environment
      let prefix = URL(string: environment["SPARKLE_URL_PREFIX"]!)!
      let archive = environment["SPARKLE_ARCHIVE_NAME"]!
      print(URL(string: archive, relativeTo: prefix)!.absoluteString)
    '
)"
if [[ "$resolved_archive_url" \
  != "$immutable_download_root/$url_fixture_commit/$url_fixture_archive" ]]
then
  fail_test "Sparkle download URL prefix resolves outside the source commit path."
fi

cleanup_fixture="$fixture_root/Cleanup Path With Spaces"
/bin/mkdir -p "$cleanup_fixture"
/bin/zsh -c '
  source "$1"
  cleanup_scope() {
    local staging_root="$1"
    install_directory_cleanup_trap "$staging_root"
  }
  cleanup_scope "$2"
' -- "$script_directory/build_release.sh" "$cleanup_fixture"
if [[ -e "$cleanup_fixture" ]]; then
  fail_test "Release staging cleanup did not survive function scope exit."
fi

dmg_retry_source="$fixture_root/DMG Retry Source"
dmg_retry_output="$fixture_root/DMG Retry.dmg"
/bin/mkdir -p "$dmg_retry_source"
/bin/zsh -c '
  source "$1"
  typeset -gi attempts=0
  run_hdiutil() {
    (( attempts += 1 ))
    local output_path="${@[-1]}"
    if [[ -e "$output_path" ]]; then
      return 90
    fi
    /usr/bin/touch "$output_path"
    (( attempts >= 3 ))
  }
  wait_for_dmg_retry() {
    :
  }
  create_dmg "$2" "$3"
  [[ "$attempts" == 3 && -f "$3" ]]
' -- "$script_directory/build_release.sh" "$dmg_retry_source" "$dmg_retry_output"

dmg_failure_output="$fixture_root/DMG Failure.dmg"
if /bin/zsh -c '
  source "$1"
  run_hdiutil() {
    /usr/bin/touch "${@[-1]}"
    return 1
  }
  wait_for_dmg_retry() {
    :
  }
  create_dmg "$2" "$3"
' -- "$script_directory/build_release.sh" "$dmg_retry_source" "$dmg_failure_output"
then
  fail_test "DMG creation succeeded after every hdiutil attempt failed."
fi
if [[ -e "$dmg_failure_output" ]]; then
  fail_test "Failed DMG output was not removed after retry exhaustion."
fi

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
