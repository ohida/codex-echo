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

## Connect Capacity history to Codex

Codex Echo includes a local, read-only MCP server that lets Codex inspect the
current Codex Capacity snapshot, purchased Credits, and the Capacity history
recorded by Echo. Purchased Credits include the balance and its observation
time, separately from earned reset credits. Purchased Credit expiry is not
exposed by the upstream response; an unavailable balance is not treated as zero.
The server runs as a separate STDIO process; it does not launch the menu bar UI or connect
to `codex app-server` itself.

After moving Codex Echo to an Applications folder, open
**Codex Echo Settings → Capacity** and click **Set Up** beside
**Use Capacity in Codex via MCP**. Echo checks the shared Codex MCP
configuration and adds its server only when `codex-echo` is not already
present. Restart Codex if the tools are not available immediately.

For local development, or to register manually, use:

```sh
codex mcp add codex-echo -- \
  "/Applications/Codex Echo.app/Contents/MacOS/CodexEcho" --mcp-stdio
```

Replace the executable path with the one inside `.build/app/Codex Echo.app`
for a local build. A matching configured registration can be removed from the
same Settings row. Echo never replaces, enables, repairs, or removes a
same-name registration whose command or arguments no longer match Echo.

Echo remains the only writer. The MCP process only reads
`CapacityHistory/current-v1.json` and the existing `CapacityHistory/v1.jsonl`;
it never repairs, rewrites, or migrates history. Current values refresh while
Echo is running. History grows only while Capacity history recording is
enabled.

## Read Capacity once as JSON

Run the development build directly without registering MCP:

```sh
".build/app/Codex Echo.app/Contents/MacOS/CodexEcho" --capacity-json
```

This command prints one JSON object and exits. It reuses the MCP snapshot reader,
without opening the UI, reading history, refreshing the account, or writing files.
It does not register MCP or require new credentials. `retrieved_at` is the read
request time; `source.current_observed_at` and `credits.observed_at` are the actual
observations. `source.kind` identifies the local Echo cache, and
`source.refreshed_upstream` is false for cache-only reads. Freshness uses the same six-minute
threshold and availability checks as MCP; it is not proof of a live server read.

- `windows` contains each observed window's remaining percentage, duration, and
  reset time when available. Missing windows are an empty array, not 100% remaining.
- `credits.balance` preserves the exact upstream string, including `"0"`.
  Unknown balance is null with `balance_status: "unknown"`. Purchased-credit expiry
  is explicitly `not_provided_by_source`; it is never inferred from reset credits.
- `reset_credits` preserves the observed count and known expiry dates, if present.
  These dates may be incomplete. Cache-only reads report freshness as `unknown`
  because existing snapshots do not record an independent reset-credit observation
  time. A missing count is null, not zero. Do not recommend spending a reset from
  this cache alone.
- Missing or stale observations still produce JSON with exit code 0. Unreadable,
  malformed, or unsupported snapshots produce a static `snapshot_unreadable` error
  and exit code 1. Unknown or extra arguments produce `invalid_arguments` and exit code 64.

For an explicit live observation using the existing signed-in Codex session:

```sh
".build/app/Codex Echo.app/Contents/MacOS/CodexEcho" --capacity-json --refresh
```

`--refresh` uses Echo's existing app-server client, with a 20-second deadline. It
starts its own short-lived app-server process, waits for a usage observation, and
stops only that child. It never starts, stops, or replaces the menu bar app. The
client uses its ordinary read-only usage and catalog requests; no task content is
returned by this command. It does not sign in, reset limits, buy credits, register
MCP, or expose credentials. Failure returns a static `refresh_unavailable` or
`refresh_timed_out` error and exit code 1, never a silent fallback to stale cache.

Live output uses `source.kind: "codex_app_server_live_observation"` and
`source.refreshed_upstream: true`. It is rendered in memory and does not overwrite
Echo's shared cache or history, so an installed release that lacks the MCP writer
can keep running safely. Use `--refresh` each time a current observation is needed;
the plain command continues to read only the existing cache. When the response
supplies reset credits, their `observed_at` records the local response receipt time,
with `observation_source: "app_server_response_received"`; freshness is calculated
from that timestamp. `upstream_observed_at` remains null because the server does
not supply its own observation timestamp. Sparse updates preserve the summary's
original receipt time rather than refreshing it. Missing fields and values without
receipt evidence remain unknown. Reset expiry dates are separate upstream values;
a missing observation timestamp does not mean the expiry dates are unavailable.

An assistant with an already authorized way to run commands on this Mac can call
this command and return its JSON to the requesting conversation. Local STDIO MCP
and this command do not make a cloud endpoint available. Direct remote access
would require a separately authorized remote service or tunnel and authentication.
When Echo is not collecting observations, the command returns missing or stale
cache data; it never starts or replaces Echo to obtain fresher data.

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
commit SHA and explicitly inherits protected signing secrets. The manual Apple
credential preflight calls that same pinned workflow through the same secret
boundary before any release tag is created. That pinned workflow:

1. requires workflow attempt 1, an unchanged direct tag, a tagged source commit
   on `main`, and a completed successful aggregate CI run for that exact commit;
2. builds the tagged source without release secrets;
3. signs, notarizes, and staples the app before packaging it as the final ZIP,
   and separately signs, notarizes, and staples the DMG in the protected Apple
   environment;
4. signs the Sparkle appcast in a separate protected environment;
5. embeds the tagged `release-notes/<version>.md` in the update dialog while
   keeping the GitHub Release as the Version History destination;
6. creates GitHub artifact attestations for those exact three files; and
7. retains those files as one immutable workflow artifact.

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
The ZIP and DMG are attached to an immutable GitHub Release. The appcast remains
an attested build output and is published only through its immutable and Stable
R2 URLs. No publication step rebuilds or re-signs these files.

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
