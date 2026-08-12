# Codex Echo

Codex Echo is a native macOS menu bar app for following Codex tasks. It shows
task state, current activity, elapsed time, completion, and account capacity so
you can return to work that needs attention.

This repository is the public source for official Codex Echo releases. It
contains the code and resources used to build the app. Apple and Sparkle
credentials are isolated in separate protected GitHub environments; R2
publication credentials stay outside the repository and its workflows.

Codex Echo depends on unpublished Codex desktop interfaces and the experimental
`codex app-server` command. Those interfaces can change without notice and are
not exposed here as supported libraries.

## Build locally

Requirements:

- Apple silicon Mac running macOS 14 or later
- Xcode with Swift 6

Build an update-disabled, ad-hoc-signed app bundle:

```sh
./scripts/build_app.sh
```

The result is `.build/app/Codex Echo.app`. This local build neither needs nor
accepts release signing, notarization, update-signing, or publication
credentials.

## Test and contribute

Run the public test suite with:

```sh
swift test
```

Pull requests are welcome for focused changes to the public source. Run both
`swift test` and `./scripts/build_app.sh` before opening a pull request, and add
or update regression tests when behavior changes. Pull-request CI uses only the
public checkout and does not receive release credentials.

Codex Echo relies on unsupported Codex desktop interfaces, so changes to those
integration boundaries should preserve graceful failure and reconnection when
the external protocol is missing, malformed, or changes unexpectedly.

## Official releases

Release tags are lightweight tags named `v<version>-build.<build>`. The
tag-triggered workflow calls the trusted release workflow at a reviewed full
commit SHA. That pinned workflow:

1. requires workflow attempt 1, an unchanged direct tag, a tagged source commit
   on `main`, and a completed successful aggregate CI run for that exact commit;
2. builds the tagged source without release secrets;
3. signs, notarizes, and staples the app before packaging it as the final ZIP,
   and separately signs, notarizes, and staples the DMG in the protected Apple
   environment;
4. signs the Sparkle appcast in a separate protected environment;
5. creates GitHub artifact attestations for those exact three files; and
6. retains those files as one immutable workflow artifact.

Repository rules reject updates or deletion of release tags. The workflow also
re-resolves the tag before signing and attestation, and refuses a moved tag.
The signing environments require an explicit owner approval before credentials
are exposed. A failed release workflow is not rerun; the next attempt uses a
higher build number and a new immutable tag.

Before creating a release tag, the operator runs the manual Apple credential
preflight on `main`. It uses the same protected environment, macOS runner, and
Developer ID import script as the release build, but creates no release tag or
artifact. Only a successful first-attempt preflight for the reviewed builder
commit is valid for the next release start.

The pinned workflow completes its native-signature, notarization, and appcast
integrity checks before attesting the exact files. The release promoter accepts
only files whose attestations bind them to the release tag and pinned workflow.
The same verified bytes are attached to an immutable GitHub Release and
promoted to the R2 Stable update location. No publication step rebuilds or
re-signs them.

To verify a downloaded release against its public source and pinned builder,
read the source commit from the release tag and the builder commit from
`.github/workflows/release.yml`, then run:

```sh
TAG=v0.6.0-build.23
SOURCE_COMMIT="$(git rev-list -n 1 "$TAG")"
BUILDER_COMMIT="$(sed -nE 's|.*release-build\.yml@([0-9a-f]{40}).*|\1|p' \
  .github/workflows/release.yml)"

gh attestation verify Codex-Echo-0.6.0-build.23.zip \
  --repo ohida/codex-echo \
  --signer-workflow ohida/codex-echo/.github/workflows/release-build.yml \
  --signer-digest "$BUILDER_COMMIT" \
  --source-ref "refs/tags/$TAG" \
  --source-digest "$SOURCE_COMMIT" \
  --deny-self-hosted-runners
```

Run the same verification for the DMG and `appcast.xml`. The attestation proves
which public tag and reviewed GitHub-hosted workflow produced the bytes; it is
not a claim that separate builds are byte-for-byte reproducible. Developer ID
signing and Apple notarization can be checked independently with `codesign`,
`spctl`, and `xcrun stapler`.

## License

The source and build-required resources are licensed under the
[Apache License 2.0](LICENSE). Third-party notices are in
[THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES).

Copyright © 2026 Takashi Ohida. `Codex Echo` and its icon identify the official
project and do not grant trademark rights to modified distributions. Codex is a
trademark of OpenAI, L.L.C. This project is independent and is not affiliated
with, endorsed by, or sponsored by OpenAI.
