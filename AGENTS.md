# Repository guidance

- Treat every tracked file, commit message, workflow log, artifact, and attestation as public.
- Keep the repository surface focused on building, testing, reviewing, and releasing Codex Echo. Do not add policy files, templates, generated manifests, or documentation only because they are common in other open-source repositories.
- Never add credentials, private keys, personal paths, local operator state, unpublished material, or internal AI and release-operations configuration.
- Product behavior tests belong beside the public source. Add or update regression tests when behavior changes; do not hide acceptance coverage in an unpublished test suite.
- Before submitting a change, run `swift test` and `./scripts/build_app.sh` from the public checkout.
- Keep the public package contract limited to the `CodexEcho` executable and its implementation and test targets. Do not expose internal transport modules as supported library products.
- Changes to `.github/workflows/release-build.yml`, `scripts/build_release.sh`, or the pinned release caller change the trusted release builder. Review builder changes separately from ordinary product changes.
- Pull-request CI must not receive release credentials or publish artifacts. Official release artifacts are produced only from an immutable release tag by the reviewed, SHA-pinned GitHub-hosted workflow.
- Do not create or update tags, releases, attestations, deployment state, or R2 objects as part of ordinary development or pull-request work.
- If public quality, licensing, provenance, or credential boundaries are uncertain, stop and leave the material unpublished.
