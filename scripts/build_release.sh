#!/bin/zsh

set -euo pipefail

official_repository="ohida/codex-echo"
official_repository_url="https://github.com/ohida/codex-echo"
stable_feed_url="https://updates.ohida.app/codex-echo/appcast.xml"
immutable_download_root="https://updates.ohida.app/codex-echo/releases"
sparkle_version="2.9.4"
sparkle_revision="b6496a74a087257ef5e6da1c5b29a447a60f5bd7"
sparkle_archive_url="https://github.com/sparkle-project/Sparkle/releases/download/2.9.4/Sparkle-for-Swift-Package-Manager.zip"
sparkle_archive_sha256="cb6fdbdc8884f15d62a616e79face92b08322410fd2d425edc6596ccbf4ba3b0"
sparkle_public_key="cMXp1w6Tx8sJunwcUo2JG7vQ/qO63do4we0TpqgV34s="
expected_team_identifier="8TV3JS3N25"

die() {
  print -u2 -- "$1"
  exit 1
}

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{ print $1 }'
}

run_codesign() {
  /usr/bin/codesign "$@"
}

run_hdiutil() {
  /usr/bin/hdiutil "$@"
}

wait_for_dmg_retry() {
  /bin/sleep "$1"
}

sparkle_download_url_prefix() {
  if (( $# != 1 )); then
    die "Usage: sparkle_download_url_prefix <source-commit>"
  fi
  print -rn -- "$immutable_download_root/$1/"
}

validate_release_notes_file() {
  if (( $# != 1 )); then
    die "Usage: validate_release_notes_file <path>"
  fi
  local release_notes="$1"
  if [[ ! -f "$release_notes" || ! -s "$release_notes" ]]; then
    die "Release notes must be a nonempty regular file: $release_notes"
  fi
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" != '- '* || "$line" == '- ' || ${#line} -gt 80 ]]; then
      die "Release notes must contain only nonempty bullets of at most 80 characters."
    fi
  done < "$release_notes"
}

verify_appcast_release_notes() {
  if (( $# != 3 )); then
    die "Usage: verify_appcast_release_notes <appcast> <notes> <history-url>"
  fi
  local appcast="$1"
  local release_notes="$2"
  local history_url="$3"
  local embedded_notes
  local expected_notes

  validate_release_notes_file "$release_notes"
  if [[ "$(/usr/bin/xmllint --xpath \
      'count((//*[local-name()="item"])[1]/*[local-name()="description"])' \
      "$appcast")" != "1" \
    || "$(/usr/bin/xmllint --xpath \
      'string((//*[local-name()="item"])[1]/*[local-name()="description"]/@*[local-name()="format"])' \
      "$appcast")" != "markdown" \
    || "$(/usr/bin/xmllint --xpath \
      'count((//*[local-name()="item"])[1]/*[local-name()="releaseNotesLink"])' \
      "$appcast")" != "0" \
    || "$(/usr/bin/xmllint --xpath \
      'count((//*[local-name()="item"])[1]/*[local-name()="fullReleaseNotesLink"])' \
      "$appcast")" != "1" \
    || "$(/usr/bin/xmllint --xpath \
      'string((//*[local-name()="item"])[1]/*[local-name()="fullReleaseNotesLink"])' \
      "$appcast")" != "$history_url" ]]
  then
    die "Appcast release-note presentation metadata is invalid."
  fi
  embedded_notes="$(/usr/bin/xmllint --xpath \
    'string((//*[local-name()="item"])[1]/*[local-name()="description"])' \
    "$appcast")"
  expected_notes="$(<"$release_notes")"
  if [[ "$embedded_notes" != "$expected_notes" ]]; then
    die "Appcast release notes do not match the tagged source."
  fi
}

create_dmg() {
  if (( $# != 2 )); then
    die "Usage: create_dmg <source-folder> <output-path>"
  fi
  local source_folder="$1"
  local output_path="$2"
  local attempt=1
  local maximum_attempts=3

  while (( attempt <= maximum_attempts )); do
    /bin/rm -f -- "$output_path"
    if run_hdiutil create \
      -volname "Codex Echo" \
      -srcfolder "$source_folder" \
      -format UDZO \
      -ov \
      "$output_path" >/dev/null
    then
      return 0
    fi

    /bin/rm -f -- "$output_path"
    if (( attempt == maximum_attempts )); then
      break
    fi
    print -u2 -- \
      "hdiutil create failed on attempt $attempt; retrying."
    wait_for_dmg_retry 2
    (( attempt += 1 ))
  done

  die "hdiutil create failed after $maximum_attempts attempts."
}

install_directory_cleanup_trap() {
  if (( $# != 1 )); then
    die "Usage: install_directory_cleanup_trap <directory>"
  fi
  local directory="$1"
  trap "/bin/rm -rf -- ${(q)directory}" EXIT
}

require_value() {
  local name="$1"
  local value="${(P)name:-}"
  if [[ -z "$value" ]]; then
    die "$name is required."
  fi
}

existing_directory() {
  local path="$1"
  local label="$2"
  if [[ ! -d "$path" ]]; then
    die "$label does not exist: $path"
  fi
  (cd "$path" && pwd -P)
}

require_empty_destination() {
  local destination="$1"
  if [[ -e "$destination" ]]; then
    die "Destination already exists: $destination"
  fi
  /bin/mkdir -p "$destination"
}

release_identity() {
  local source_ref="${SOURCE_REF:-}"
  local source_tag

  if [[ "${SOURCE_REPOSITORY:-}" != "$official_repository" ]]; then
    die "SOURCE_REPOSITORY must be $official_repository."
  fi
  if [[ ! "${SOURCE_COMMIT:-}" =~ '^[0-9a-f]{40}$' ]]; then
    die "SOURCE_COMMIT must be a full lowercase Git SHA."
  fi
  if [[ ! "${BUILDER_COMMIT:-}" =~ '^[0-9a-f]{40}$' ]]; then
    die "BUILDER_COMMIT must be a full lowercase Git SHA."
  fi
  if [[ "$source_ref" != refs/tags/* ]]; then
    die "SOURCE_REF must be a tag ref."
  fi
  source_tag="${source_ref#refs/tags/}"
  if [[ ! "$source_tag" =~ '^v[0-9]+(\.[0-9]+){1,2}-build\.[1-9][0-9]*$' ]]; then
    die "Release tags must use v<version>-build.<build>."
  fi

  RELEASE_TAG="$source_tag"
  RELEASE_VERSION="${source_tag#v}"
  RELEASE_VERSION="${RELEASE_VERSION%-build.*}"
  RELEASE_BUILD="${source_tag##*.}"
}

validate_source_package() {
  local source_root="$1"
  local package_description
  local plist_version
  local plist_build
  local plist_value

  for required_file in \
    Package.swift \
    Package.resolved \
    Resources/Info.plist \
    Resources/AppIcon-1024.png \
    LICENSE \
    THIRD_PARTY_NOTICES
  do
    if [[ ! -s "$source_root/$required_file" ]]; then
      die "Missing source input: $required_file"
    fi
  done
  validate_release_notes_file "$source_root/release-notes/$RELEASE_VERSION.md"

  /usr/bin/plutil -lint "$source_root/Resources/Info.plist" >/dev/null
  plist_version="$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' \
    "$source_root/Resources/Info.plist")"
  plist_build="$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleVersion' \
    "$source_root/Resources/Info.plist")"
  if [[ "$plist_version" != "$RELEASE_VERSION" || "$plist_build" != "$RELEASE_BUILD" ]]; then
    die "Info.plist version/build does not match $RELEASE_TAG."
  fi
  for key_and_value in \
    'CFBundleExecutable=CodexEcho' \
    'CFBundleIdentifier=app.ohida.codex-echo' \
    'CFBundleIconFile=AppIcon' \
    'CFBundlePackageType=APPL' \
    'LSMinimumSystemVersion=14.0'
  do
    local plist_key="${key_and_value%%=*}"
    local expected_value="${key_and_value#*=}"
    plist_value="$(/usr/libexec/PlistBuddy \
      -c "Print :$plist_key" \
      "$source_root/Resources/Info.plist")"
    if [[ "$plist_value" != "$expected_value" ]]; then
      die "Info.plist $plist_key must be $expected_value."
    fi
  done
  if [[ "$(/usr/libexec/PlistBuddy \
    -c 'Print :CodexEchoUpdatesEnabled' \
    "$source_root/Resources/Info.plist")" != "false" ]]
  then
    die "Public source builds must default to updates disabled."
  fi

  package_description="$(mktemp "${TMPDIR:-/tmp}/codex-echo-package.XXXXXX")"
  /usr/bin/swift package \
    --package-path "$source_root" \
    dump-package > "$package_description"
  if ! /usr/bin/jq -e --arg sparkleVersion "$sparkle_version" '
    def target($name): .targets[] | select(.name == $name);
    (.name == "CodexEcho")
    and (.toolsVersion._version == "6.0.0")
    and (.platforms == [{options: [], platformName: "macos", version: "14.0"}])
    and (.swiftLanguageVersions == null)
    and (.cLanguageStandard == null)
    and (.cxxLanguageStandard == null)
    and (.pkgConfig == null)
    and (.providers == null)
    and (.traits == [])
    and (.products | length == 1)
    and (.products[0].name == "CodexEcho")
    and (.products[0].targets == ["CodexEcho"])
    and (.products[0].type.executable == null)
    and (.dependencies | length == 1)
    and (.dependencies[0].sourceControl | length == 1)
    and (.dependencies[0].sourceControl[0].identity == "sparkle")
    and (.dependencies[0].sourceControl[0].productFilter == null)
    and (.dependencies[0].sourceControl[0].traits == [{name: "default"}])
    and (
      .dependencies[0].sourceControl[0].location.remote[0].urlString
      == "https://github.com/sparkle-project/Sparkle"
    )
    and (
      .dependencies[0].sourceControl[0].requirement.exact[0]
      == $sparkleVersion
    )
    and (
      [.targets[].name] | sort
      == [
        "CodexAppServer",
        "CodexAppServerTests",
        "CodexEcho",
        "CodexEchoTests",
        "CodexIPC",
        "CodexIPCTests"
      ]
    )
    and (target("CodexIPC").type == "regular")
    and (target("CodexIPC").dependencies == [])
    and (target("CodexAppServer").type == "regular")
    and (target("CodexAppServer").dependencies == [])
    and (target("CodexAppServerTests").type == "test")
    and (
      target("CodexAppServerTests").dependencies
      == [{byName: ["CodexAppServer", null]}]
    )
    and (target("CodexEcho").type == "executable")
    and (
      [target("CodexEcho").dependencies[]
        | if has("byName") then "target:\(.byName[0])"
          else "product:\(.product[0])@\(.product[1])"
          end]
      | sort
      == [
        "product:Sparkle@Sparkle",
        "target:CodexAppServer",
        "target:CodexIPC"
      ]
    )
    and (target("CodexEchoTests").type == "test")
    and (
      target("CodexEchoTests").dependencies
      == [{byName: ["CodexEcho", null]}]
    )
    and (target("CodexIPCTests").type == "test")
    and (
      target("CodexIPCTests").dependencies
      == [{byName: ["CodexIPC", null]}]
    )
    and all(.targets[];
      (.exclude == []) and (.resources == []) and (.settings == []))
  ' "$package_description" >/dev/null
  then
    /bin/rm -f -- "$package_description"
    die "The public package must expose only the CodexEcho executable."
  fi
  /bin/rm -f -- "$package_description"

  if ! /usr/bin/jq -e \
    --arg version "$sparkle_version" \
    --arg revision "$sparkle_revision" '
      (.pins | length == 1)
      and (.pins[0].identity == "sparkle")
      and (.pins[0].kind == "remoteSourceControl")
      and (.pins[0].location == "https://github.com/sparkle-project/Sparkle")
      and (.pins[0].state.version == $version)
      and (.pins[0].state.revision == $revision)
    ' "$source_root/Package.resolved" >/dev/null
  then
    die "Package.resolved does not contain the reviewed Sparkle pin."
  fi
}

prepare_source() {
  if (( $# != 2 )); then
    die "Usage: build_release.sh prepare-source <source-root> <payload-directory>"
  fi
  local source_root
  local payload_directory="$2"
  local bin_path
  local executable_sha
  local info_sha
  local icon_sha
  local license_sha
  local notices_sha
  local release_notes_sha

  source_root="$(existing_directory "$1" "Source root")"
  release_identity
  validate_source_package "$source_root"
  require_empty_destination "$payload_directory"

  /usr/bin/swift build \
    --package-path "$source_root" \
    --configuration release \
    --product CodexEcho
  bin_path="$(/usr/bin/swift build \
    --package-path "$source_root" \
    --configuration release \
    --show-bin-path)"
  if [[ ! -x "$bin_path/CodexEcho" ]]; then
    die "SwiftPM did not produce CodexEcho."
  fi
  if [[ "$(/usr/bin/lipo -archs "$bin_path/CodexEcho")" != "arm64" ]]; then
    die "Official releases are arm64-only."
  fi

  /bin/cp "$bin_path/CodexEcho" "$payload_directory/CodexEcho"
  /bin/cp "$source_root/Resources/Info.plist" "$payload_directory/Info.plist"
  /bin/cp \
    "$source_root/Resources/AppIcon-1024.png" \
    "$payload_directory/AppIcon-1024.png"
  /bin/cp "$source_root/LICENSE" "$payload_directory/LICENSE"
  /bin/cp \
    "$source_root/THIRD_PARTY_NOTICES" \
    "$payload_directory/THIRD_PARTY_NOTICES"
  /bin/cp \
    "$source_root/release-notes/$RELEASE_VERSION.md" \
    "$payload_directory/release-notes.md"
  /bin/chmod 755 "$payload_directory/CodexEcho"
  /bin/chmod 644 \
    "$payload_directory/Info.plist" \
    "$payload_directory/AppIcon-1024.png" \
    "$payload_directory/LICENSE" \
    "$payload_directory/THIRD_PARTY_NOTICES" \
    "$payload_directory/release-notes.md"

  executable_sha="$(sha256_file "$payload_directory/CodexEcho")"
  info_sha="$(sha256_file "$payload_directory/Info.plist")"
  icon_sha="$(sha256_file "$payload_directory/AppIcon-1024.png")"
  license_sha="$(sha256_file "$payload_directory/LICENSE")"
  notices_sha="$(sha256_file "$payload_directory/THIRD_PARTY_NOTICES")"
  release_notes_sha="$(sha256_file "$payload_directory/release-notes.md")"
  /usr/bin/jq -n \
    --arg repository "$SOURCE_REPOSITORY" \
    --arg ref "$SOURCE_REF" \
    --arg commit "$SOURCE_COMMIT" \
    --arg builderCommit "$BUILDER_COMMIT" \
    --arg tag "$RELEASE_TAG" \
    --arg version "$RELEASE_VERSION" \
    --arg build "$RELEASE_BUILD" \
    --arg executableSHA256 "$executable_sha" \
    --arg infoSHA256 "$info_sha" \
    --arg iconSHA256 "$icon_sha" \
    --arg licenseSHA256 "$license_sha" \
    --arg noticesSHA256 "$notices_sha" \
    --arg releaseNotesSHA256 "$release_notes_sha" \
    '{
      schemaVersion: 1,
      source: {
        repository: $repository,
        ref: $ref,
        commit: $commit,
        tag: $tag
      },
      builderCommit: $builderCommit,
      version: $version,
      build: $build,
      files: {
        CodexEcho: $executableSHA256,
        "Info.plist": $infoSHA256,
        "AppIcon-1024.png": $iconSHA256,
        LICENSE: $licenseSHA256,
        THIRD_PARTY_NOTICES: $noticesSHA256,
        "release-notes.md": $releaseNotesSHA256
      }
    }' > "$payload_directory/identity.json"
  /bin/chmod 644 "$payload_directory/identity.json"
}

validate_payload() {
  local payload_directory="$1"
  local identity="$payload_directory/identity.json"
  local entry_count
  local expected_tag="$RELEASE_TAG"
  local expected_version="$RELEASE_VERSION"
  local expected_build="$RELEASE_BUILD"

  if [[ ! -d "$payload_directory" || ! -s "$identity" ]]; then
    die "Missing source payload."
  fi
  entry_count="$(/usr/bin/find "$payload_directory" \
    -mindepth 1 -maxdepth 1 -print | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')"
  if [[ "$entry_count" != "7" ]]; then
    die "Source payload must contain exactly seven files."
  fi
  if [[ -n "$(/usr/bin/find "$payload_directory" \
    -mindepth 1 -maxdepth 1 ! -type f -print -quit)" ]]
  then
    die "Source payload may contain only regular files."
  fi

  if [[ "$(/usr/bin/jq -r '.source.repository' "$identity")" != "$official_repository" \
    || "$(/usr/bin/jq -r '.source.ref' "$identity")" != "${SOURCE_REF:-}" \
    || "$(/usr/bin/jq -r '.source.commit' "$identity")" != "${SOURCE_COMMIT:-}" \
    || "$(/usr/bin/jq -r '.builderCommit' "$identity")" != "${BUILDER_COMMIT:-}" ]]
  then
    die "Source payload identity does not match the workflow."
  fi

  local file
  for file in \
    CodexEcho \
    Info.plist \
    AppIcon-1024.png \
    LICENSE \
    THIRD_PARTY_NOTICES \
    release-notes.md
  do
    if [[ ! -s "$payload_directory/$file" ]]; then
      die "Missing payload file: $file"
    fi
    if [[ "$(sha256_file "$payload_directory/$file")" \
      != "$(/usr/bin/jq -r --arg file "$file" '.files[$file]' "$identity")" ]]
    then
      die "Payload hash mismatch: $file"
    fi
  done
  validate_release_notes_file "$payload_directory/release-notes.md"

  if [[ "$(/usr/bin/jq -r '.source.tag' "$identity")" != "$expected_tag" \
    || "$(/usr/bin/jq -r '.version' "$identity")" != "$expected_version" \
    || "$(/usr/bin/jq -r '.build' "$identity")" != "$expected_build" ]]
  then
    die "Source payload version identity does not match the workflow."
  fi
}

download_sparkle() {
  local destination="$1"
  local archive="$destination/Sparkle.zip"
  /bin/mkdir -p "$destination"
  /usr/bin/curl \
    --fail \
    --location \
    --proto '=https' \
    --tlsv1.2 \
    --output "$archive" \
    "$sparkle_archive_url"
  if [[ "$(sha256_file "$archive")" != "$sparkle_archive_sha256" ]]; then
    die "Sparkle archive checksum mismatch."
  fi
  /usr/bin/ditto -x -k "$archive" "$destination/extracted"
}

make_icon() {
  local icon_source="$1"
  local iconset="$2"
  local output="$3"
  local size
  local filename

  shift 3
  while (( $# > 0 )); do
    if (( $# < 2 )); then
      die "Icon sizes must be provided as size/name pairs."
    fi
    size="$1"
    filename="$2"
    /usr/bin/sips \
      -z "$size" "$size" \
      "$icon_source" \
      --out "$iconset/$filename" >/dev/null
    shift 2
  done
  /usr/bin/iconutil -c icns "$iconset" -o "$output"
}

sign_app() {
  local app="$1"
  local identity="$2"
  local framework="$app/Contents/Frameworks/Sparkle.framework"
  local framework_version

  framework_version="$(cd "$framework/Versions/Current" && pwd -P)"
  local signed_paths=(
    "$framework_version/XPCServices/Installer.xpc"
    "$framework_version/XPCServices/Downloader.xpc"
    "$framework_version/Autoupdate"
    "$framework_version/Updater.app"
    "$framework"
    "$app"
  )
  local signed_path
  for signed_path in "${signed_paths[@]}"; do
    if [[ ! -e "$signed_path" ]]; then
      die "Missing nested code: $signed_path"
    fi
  done

  run_codesign \
    --force --sign "$identity" --options runtime --timestamp \
    "$signed_paths[1]"
  run_codesign \
    --force --sign "$identity" --options runtime --timestamp \
    --preserve-metadata=entitlements \
    "$signed_paths[2]"
  for signed_path in \
    "$signed_paths[3]" \
    "$signed_paths[4]" \
    "$signed_paths[5]" \
    "$signed_paths[6]"
  do
    run_codesign \
      --force --sign "$identity" --options runtime --timestamp \
      "$signed_path"
  done
}

verify_app() {
  local app="$1"
  local post_notarization="$2"
  local framework="$app/Contents/Frameworks/Sparkle.framework"
  local framework_version
  local signed_path

  framework_version="$(cd "$framework/Versions/Current" && pwd -P)"
  local signed_paths=(
    "$framework_version/XPCServices/Installer.xpc"
    "$framework_version/XPCServices/Downloader.xpc"
    "$framework_version/Autoupdate"
    "$framework_version/Updater.app"
    "$framework"
    "$app"
  )
  for signed_path in "${signed_paths[@]}"; do
    /usr/bin/codesign --verify --strict --verbose=2 "$signed_path"
    local details="$(/usr/bin/codesign --display --verbose=4 "$signed_path" 2>&1)"
    local team="$(print -r -- "$details" \
      | /usr/bin/sed -n 's/^TeamIdentifier=//p' \
      | /usr/bin/head -n 1)"
    if [[ "$details" != *"flags="*"runtime"* \
      || "$details" == *"Signature=adhoc"* \
      || -z "$team" \
      || "$team" == "not set" ]]
    then
      die "Invalid Developer ID signature: $signed_path"
    fi
    if [[ "$team" != "$expected_team_identifier" ]]; then
      die "Unexpected TeamIdentifier on signed code: $signed_path"
    fi
  done

  if [[ "$(/usr/bin/lipo -archs "$app/Contents/MacOS/CodexEcho")" != "arm64" ]]; then
    die "Distribution executable must be arm64-only."
  fi
  if [[ "$(/usr/libexec/PlistBuddy \
    -c 'Print :CodexEchoUpdatesEnabled' \
    "$app/Contents/Info.plist")" != "true" \
    || "$(/usr/libexec/PlistBuddy \
      -c 'Print :CFBundleShortVersionString' \
      "$app/Contents/Info.plist")" != "$RELEASE_VERSION" \
    || "$(/usr/libexec/PlistBuddy \
      -c 'Print :CFBundleVersion' \
      "$app/Contents/Info.plist")" != "$RELEASE_BUILD" \
    || "$(/usr/libexec/PlistBuddy \
      -c 'Print :SUFeedURL' \
      "$app/Contents/Info.plist")" != "$stable_feed_url" \
    || "$(/usr/libexec/PlistBuddy \
      -c 'Print :SUPublicEDKey' \
      "$app/Contents/Info.plist")" != "$sparkle_public_key" \
    || "$(/usr/libexec/PlistBuddy \
      -c 'Print :SUEnableAutomaticChecks' \
      "$app/Contents/Info.plist")" != "true" \
    || "$(/usr/libexec/PlistBuddy \
      -c 'Print :CodexEchoPublicSourceRepository' \
      "$app/Contents/Info.plist")" != "$official_repository_url" \
    || "$(/usr/libexec/PlistBuddy \
      -c 'Print :CodexEchoPublicSourceTag' \
      "$app/Contents/Info.plist")" != "$RELEASE_TAG" \
    || "$(/usr/libexec/PlistBuddy \
      -c 'Print :CodexEchoPublicSourceCommit' \
      "$app/Contents/Info.plist")" != "$SOURCE_COMMIT" ]]
  then
    die "Distribution app metadata does not match the release identity."
  fi
  for absent_key in SUAutomaticallyUpdate CodexEchoSourceManifestSHA256; do
    if /usr/libexec/PlistBuddy \
      -c "Print :$absent_key" \
      "$app/Contents/Info.plist" >/dev/null 2>&1
    then
      die "Distribution app contains obsolete metadata: $absent_key"
    fi
  done
  if [[ "$post_notarization" == "true" ]]; then
    /usr/bin/xcrun stapler validate "$app"
    /usr/sbin/spctl --assess --type execute --verbose=4 "$app"
  fi
}

apple_finalize() {
  if (( $# != 2 )); then
    die "Usage: build_release.sh apple-finalize <payload-directory> <output-directory>"
  fi
  local payload_directory
  local output_directory="$2"
  local staging_root
  local sparkle_root
  local sparkle_framework
  local app
  local contents
  local resources
  local iconset
  local pre_notary_zip
  local final_zip
  local final_dmg
  local dmg_root
  local app_cdhash
  local team_identifier
  local release_notes_sha

  payload_directory="$(existing_directory "$1" "Source payload")"
  require_value CODE_SIGN_IDENTITY
  require_value APPLE_NOTARY_KEY_PATH
  require_value APPLE_NOTARY_KEY_ID
  require_value APPLE_NOTARY_ISSUER_ID
  release_identity
  validate_payload "$payload_directory"
  require_empty_destination "$output_directory"

  staging_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-echo-release.XXXXXX")"
  install_directory_cleanup_trap "$staging_root"
  sparkle_root="$staging_root/sparkle"
  download_sparkle "$sparkle_root"
  sparkle_framework="$sparkle_root/extracted/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
  if [[ ! -d "$sparkle_framework" ]]; then
    die "Sparkle archive does not contain the expected framework."
  fi

  app="$staging_root/Codex Echo.app"
  contents="$app/Contents"
  resources="$contents/Resources"
  iconset="$staging_root/AppIcon.iconset"
  /bin/mkdir -p \
    "$contents/MacOS" \
    "$contents/Frameworks" \
    "$resources" \
    "$iconset"
  /bin/cp "$payload_directory/CodexEcho" "$contents/MacOS/CodexEcho"
  /bin/chmod 755 "$contents/MacOS/CodexEcho"
  /usr/bin/ditto "$sparkle_framework" "$contents/Frameworks/Sparkle.framework"
  if ! /usr/bin/otool -l "$contents/MacOS/CodexEcho" \
    | /usr/bin/grep -F '@executable_path/../Frameworks' >/dev/null
  then
    /usr/bin/install_name_tool \
      -add_rpath '@executable_path/../Frameworks' \
      "$contents/MacOS/CodexEcho"
  fi

  /bin/cp "$payload_directory/Info.plist" "$contents/Info.plist"
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
  /usr/libexec/PlistBuddy \
    -c "Set :CodexEchoUpdatesEnabled true" \
    "$contents/Info.plist"
  /usr/libexec/PlistBuddy \
    -c "Add :SUFeedURL string $stable_feed_url" \
    "$contents/Info.plist"
  /usr/libexec/PlistBuddy \
    -c "Add :SUPublicEDKey string $sparkle_public_key" \
    "$contents/Info.plist"
  /usr/libexec/PlistBuddy \
    -c "Add :SUEnableAutomaticChecks bool true" \
    "$contents/Info.plist"
  /usr/libexec/PlistBuddy \
    -c "Add :CodexEchoPublicSourceRepository string $official_repository_url" \
    "$contents/Info.plist"
  /usr/libexec/PlistBuddy \
    -c "Add :CodexEchoPublicSourceTag string $RELEASE_TAG" \
    "$contents/Info.plist"
  /usr/libexec/PlistBuddy \
    -c "Add :CodexEchoPublicSourceCommit string $SOURCE_COMMIT" \
    "$contents/Info.plist"

  make_icon \
    "$payload_directory/AppIcon-1024.png" \
    "$iconset" \
    "$resources/AppIcon.icns" \
    16 icon_16x16.png \
    32 icon_16x16@2x.png \
    32 icon_32x32.png \
    64 icon_32x32@2x.png \
    128 icon_128x128.png \
    256 icon_128x128@2x.png \
    256 icon_256x256.png \
    512 icon_256x256@2x.png \
    512 icon_512x512.png \
    1024 icon_512x512@2x.png
  /bin/cp "$payload_directory/LICENSE" "$resources/LICENSE"
  /bin/cp \
    "$payload_directory/THIRD_PARTY_NOTICES" \
    "$resources/THIRD_PARTY_NOTICES"
  /bin/chmod 644 "$resources/LICENSE" "$resources/THIRD_PARTY_NOTICES"
  /usr/bin/plutil -lint "$contents/Info.plist" >/dev/null

  sign_app "$app" "$CODE_SIGN_IDENTITY"
  verify_app "$app" false
  pre_notary_zip="$staging_root/pre-notarization.zip"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent \
    "$app" "$pre_notary_zip"
  /usr/bin/xcrun notarytool submit "$pre_notary_zip" \
    --key "$APPLE_NOTARY_KEY_PATH" \
    --key-id "$APPLE_NOTARY_KEY_ID" \
    --issuer "$APPLE_NOTARY_ISSUER_ID" \
    --wait
  /usr/bin/xcrun stapler staple "$app"
  verify_app "$app" true

  final_zip="$output_directory/Codex-Echo-$RELEASE_VERSION-build.$RELEASE_BUILD.zip"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent \
    "$app" "$final_zip"

  dmg_root="$staging_root/dmg-root"
  /bin/mkdir -p "$dmg_root"
  /usr/bin/ditto "$app" "$dmg_root/Codex Echo.app"
  /bin/ln -s /Applications "$dmg_root/Applications"
  final_dmg="$output_directory/Codex-Echo-$RELEASE_VERSION-build.$RELEASE_BUILD.dmg"
  create_dmg "$dmg_root" "$final_dmg"
  /usr/bin/codesign \
    --force \
    --sign "$CODE_SIGN_IDENTITY" \
    --timestamp \
    "$final_dmg"
  /usr/bin/xcrun notarytool submit "$final_dmg" \
    --key "$APPLE_NOTARY_KEY_PATH" \
    --key-id "$APPLE_NOTARY_KEY_ID" \
    --issuer "$APPLE_NOTARY_ISSUER_ID" \
    --wait
  /usr/bin/xcrun stapler staple "$final_dmg"
  /usr/bin/hdiutil verify "$final_dmg" >/dev/null
  /usr/bin/codesign --verify --verbose=4 "$final_dmg"
  if [[ "$(/usr/bin/codesign --display --verbose=4 "$final_dmg" 2>&1 \
    | /usr/bin/sed -n 's/^TeamIdentifier=//p' \
    | /usr/bin/head -n 1)" != "$expected_team_identifier" ]]
  then
    die "Distribution DMG has an unexpected TeamIdentifier."
  fi
  /usr/bin/xcrun stapler validate "$final_dmg"
  /usr/sbin/spctl \
    --assess \
    --type open \
    --context context:primary-signature \
    --verbose=4 \
    "$final_dmg"

  /bin/cp "$payload_directory/release-notes.md" \
    "$output_directory/release-notes.md"
  /bin/chmod 644 "$output_directory/release-notes.md"
  release_notes_sha="$(sha256_file "$output_directory/release-notes.md")"

  app_cdhash="$(/usr/bin/codesign --display --verbose=4 "$app" 2>&1 \
    | /usr/bin/sed -n 's/^CDHash=//p' \
    | /usr/bin/head -n 1)"
  team_identifier="$(/usr/bin/codesign --display --verbose=4 "$app" 2>&1 \
    | /usr/bin/sed -n 's/^TeamIdentifier=//p' \
    | /usr/bin/head -n 1)"
  /usr/bin/jq -n \
    --arg repository "$SOURCE_REPOSITORY" \
    --arg ref "$SOURCE_REF" \
    --arg commit "$SOURCE_COMMIT" \
    --arg builderCommit "$BUILDER_COMMIT" \
    --arg tag "$RELEASE_TAG" \
    --arg version "$RELEASE_VERSION" \
    --arg build "$RELEASE_BUILD" \
    --arg zip "$(basename "$final_zip")" \
    --arg zipSHA256 "$(sha256_file "$final_zip")" \
    --arg dmg "$(basename "$final_dmg")" \
    --arg dmgSHA256 "$(sha256_file "$final_dmg")" \
    --arg appCDHash "$app_cdhash" \
    --arg teamIdentifier "$team_identifier" \
    --arg releaseNotesSHA256 "$release_notes_sha" \
    '{
      schemaVersion: 1,
      source: {
        repository: $repository,
        ref: $ref,
        commit: $commit,
        tag: $tag
      },
      builderCommit: $builderCommit,
      version: $version,
      build: $build,
      artifacts: {
        zip: {name: $zip, sha256: $zipSHA256},
        dmg: {name: $dmg, sha256: $dmgSHA256}
      },
      releaseNotes: {
        name: "release-notes.md",
        sha256: $releaseNotesSHA256
      },
      signing: {
        appCDHash: $appCDHash,
        teamIdentifier: $teamIdentifier
      }
    }' > "$output_directory/apple-identity.json"
  /bin/chmod 644 "$output_directory/apple-identity.json"
}

sparkle_finalize() {
  if (( $# != 2 )); then
    die "Usage: build_release.sh sparkle-finalize <apple-directory> <output-directory>"
  fi
  local apple_directory
  local output_directory="$2"
  local identity
  local staging_root
  local sparkle_root
  local generate_appcast
  local sparkle_private_key
  local zip_name
  local dmg_name
  local zip_path
  local dmg_path
  local appcast_root
  local appcast_path
  local enclosure_url
  local enclosure_signature
  local enclosure_length
  local archive_length
  local download_url_prefix
  local expected_enclosure_url
  local release_notes_path
  local release_notes_name
  local history_url
  local apple_entry_count

  apple_directory="$(existing_directory "$1" "Apple artifact directory")"
  identity="$apple_directory/apple-identity.json"
  require_value SPARKLE_PRIVATE_KEY
  sparkle_private_key="$SPARKLE_PRIVATE_KEY"
  unset SPARKLE_PRIVATE_KEY
  release_identity
  if [[ ! -s "$identity" ]]; then
    die "Missing apple-identity.json."
  fi
  apple_entry_count="$(/usr/bin/find "$apple_directory" \
    -mindepth 1 -maxdepth 1 -print | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')"
  if [[ "$apple_entry_count" != "4" \
    || -n "$(/usr/bin/find "$apple_directory" \
      -mindepth 1 -maxdepth 1 ! -type f -print -quit)" ]]
  then
    die "Apple artifact payload must contain exactly four regular files."
  fi
  if [[ "$(/usr/bin/jq -r '.source.repository' "$identity")" != "$SOURCE_REPOSITORY" \
    || "$(/usr/bin/jq -r '.source.ref' "$identity")" != "$SOURCE_REF" \
    || "$(/usr/bin/jq -r '.source.commit' "$identity")" != "$SOURCE_COMMIT" \
    || "$(/usr/bin/jq -r '.builderCommit' "$identity")" != "$BUILDER_COMMIT" \
    || "$(/usr/bin/jq -r '.source.tag' "$identity")" != "$RELEASE_TAG" \
    || "$(/usr/bin/jq -r '.version' "$identity")" != "$RELEASE_VERSION" \
    || "$(/usr/bin/jq -r '.build' "$identity")" != "$RELEASE_BUILD" \
    || "$(/usr/bin/jq -r '.signing.teamIdentifier' "$identity")" \
      != "$expected_team_identifier" \
    || -z "$(/usr/bin/jq -r '.signing.appCDHash // empty' "$identity")" ]]
  then
    die "Apple artifacts do not match the workflow identity."
  fi
  release_notes_name="$(/usr/bin/jq -r '.releaseNotes.name // empty' "$identity")"
  release_notes_path="$apple_directory/$release_notes_name"
  if [[ "$release_notes_name" != "release-notes.md" \
    || ! -f "$release_notes_path" \
    || "$(sha256_file "$release_notes_path")" \
      != "$(/usr/bin/jq -r '.releaseNotes.sha256 // empty' "$identity")" ]]
  then
    die "Release notes do not match the signed Apple artifact identity."
  fi
  validate_release_notes_file "$release_notes_path"
  zip_name="$(/usr/bin/jq -r '.artifacts.zip.name' "$identity")"
  dmg_name="$(/usr/bin/jq -r '.artifacts.dmg.name' "$identity")"
  if [[ "$zip_name" != "Codex-Echo-$RELEASE_VERSION-build.$RELEASE_BUILD.zip" \
    || "$dmg_name" != "Codex-Echo-$RELEASE_VERSION-build.$RELEASE_BUILD.dmg" ]]
  then
    die "Apple artifact names do not match the release identity."
  fi
  zip_path="$apple_directory/$zip_name"
  dmg_path="$apple_directory/$dmg_name"
  if [[ ! -f "$zip_path" || ! -f "$dmg_path" \
    || "$(sha256_file "$zip_path")" \
    != "$(/usr/bin/jq -r '.artifacts.zip.sha256' "$identity")" \
    || "$(sha256_file "$dmg_path")" \
    != "$(/usr/bin/jq -r '.artifacts.dmg.sha256' "$identity")" ]]
  then
    die "Apple artifact hash mismatch."
  fi
  require_empty_destination "$output_directory"

  staging_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-echo-appcast.XXXXXX")"
  install_directory_cleanup_trap "$staging_root"
  sparkle_root="$staging_root/sparkle"
  download_sparkle "$sparkle_root"
  generate_appcast="$sparkle_root/extracted/bin/generate_appcast"
  if [[ ! -x "$generate_appcast" ]]; then
    die "Sparkle archive does not contain generate_appcast."
  fi

  appcast_root="$staging_root/appcast"
  /bin/mkdir -p "$appcast_root"
  /bin/cp "$zip_path" "$appcast_root/$zip_name"
  /bin/cp "$release_notes_path" \
    "$appcast_root/${zip_name%.zip}.md"
  download_url_prefix="$(sparkle_download_url_prefix "$SOURCE_COMMIT")"
  history_url="$official_repository_url/releases/tag/$RELEASE_TAG"
  print -rn -- "$sparkle_private_key" \
    | "$generate_appcast" \
      --ed-key-file - \
      --download-url-prefix "$download_url_prefix" \
      --embed-release-notes \
      --full-release-notes-url "$history_url" \
      --link "$official_repository_url" \
      --maximum-deltas 0 \
      --maximum-versions 1 \
      --versions "$RELEASE_BUILD" \
      -o "$appcast_root/appcast.xml" \
      "$appcast_root"
  sparkle_private_key=""
  appcast_path="$appcast_root/appcast.xml"
  if [[ "$(/usr/bin/xmllint --xpath 'count(/rss/channel/item)' "$appcast_path")" != "1" ]]; then
    die "Appcast must contain exactly one item."
  fi
  verify_appcast_release_notes "$appcast_path" "$release_notes_path" "$history_url"
  enclosure_url="$(/usr/bin/xmllint --xpath \
    'string((//*[local-name()="enclosure"])[1]/@url)' \
    "$appcast_path")"
  enclosure_signature="$(/usr/bin/xmllint --xpath \
    'string((//*[local-name()="enclosure"])[1]/@*[local-name()="edSignature"])' \
    "$appcast_path")"
  enclosure_length="$(/usr/bin/xmllint --xpath \
    'string((//*[local-name()="enclosure"])[1]/@length)' \
    "$appcast_path")"
  archive_length="$(/usr/bin/stat -f '%z' "$zip_path")"
  expected_enclosure_url="$immutable_download_root/$SOURCE_COMMIT/$zip_name"
  if [[ "$enclosure_url" != "$expected_enclosure_url" ]]; then
    die "Appcast enclosure URL does not match the immutable release URL."
  fi
  if [[ -z "$enclosure_signature" ]]; then
    die "Appcast enclosure is missing its EdDSA signature."
  fi
  if [[ "$enclosure_length" != "$archive_length" ]]; then
    die "Appcast enclosure length does not match the signed ZIP."
  fi
  if [[ "$(/usr/bin/xmllint --xpath \
    'string((//*[local-name()="item"])[1]/*[local-name()="version"])' \
    "$appcast_path")" != "$RELEASE_BUILD" ]]
  then
    die "Appcast build number mismatch."
  fi
  if [[ "$(/usr/bin/xmllint --xpath \
    'string((//*[local-name()="item"])[1]/*[local-name()="shortVersionString"])' \
    "$appcast_path")" != "$RELEASE_VERSION" \
    || "$(/usr/bin/xmllint --xpath \
      'string((//*[local-name()="item"])[1]/*[local-name()="minimumSystemVersion"])' \
      "$appcast_path")" != "14.0" \
    || "$(/usr/bin/xmllint --xpath \
      'string((//*[local-name()="item"])[1]/*[local-name()="hardwareRequirements"])' \
      "$appcast_path")" != "arm64" ]]
  then
    die "Appcast compatibility metadata does not match the release."
  fi
  SPARKLE_ARCHIVE_PATH="$zip_path" \
  SPARKLE_ARCHIVE_SIGNATURE="$enclosure_signature" \
  SPARKLE_PUBLIC_KEY="$sparkle_public_key" \
    /usr/bin/swift -e '
      import CryptoKit
      import Darwin
      import Foundation

      let environment = ProcessInfo.processInfo.environment
      guard
        let archivePath = environment["SPARKLE_ARCHIVE_PATH"],
        let signatureText = environment["SPARKLE_ARCHIVE_SIGNATURE"],
        let publicKeyText = environment["SPARKLE_PUBLIC_KEY"],
        let signature = Data(base64Encoded: signatureText),
        let publicKeyData = Data(base64Encoded: publicKeyText)
      else {
        exit(64)
      }
      let archive = try Data(
        contentsOf: URL(fileURLWithPath: archivePath),
        options: .mappedIfSafe
      )
      let publicKey = try Curve25519.Signing.PublicKey(
        rawRepresentation: publicKeyData
      )
      guard publicKey.isValidSignature(signature, for: archive) else {
        exit(1)
      }
    '

  /bin/cp "$zip_path" "$output_directory/$zip_name"
  /bin/cp "$dmg_path" "$output_directory/$dmg_name"
  /bin/cp "$appcast_path" "$output_directory/appcast.xml"
  /bin/chmod 644 "$output_directory/$zip_name" \
    "$output_directory/$dmg_name" \
    "$output_directory/appcast.xml"
}

if [[ "${ZSH_EVAL_CONTEXT:-}" == *:file ]]; then
  return 0
fi

if (( $# < 1 )); then
  die "Usage: build_release.sh <prepare-source|apple-finalize|sparkle-finalize> ..."
fi
mode="$1"
shift
case "$mode" in
  prepare-source)
    prepare_source "$@"
    ;;
  apple-finalize)
    apple_finalize "$@"
    ;;
  sparkle-finalize)
    sparkle_finalize "$@"
    ;;
  *)
    die "Unknown release build mode: $mode"
    ;;
esac
