# Releasing

This project uses a lightweight release process:

- `main` should stay releasable.
- Releases are tagged with `vX.Y.Z`.
- `VERSION` is the source of truth for the current target release version.
- `CHANGELOG.md` tracks user-visible changes.
- Semantic Versioning is used for release numbers.

## Versioning Rules

Use Semantic Versioning:

- bump `MAJOR` for breaking CLI or config contract changes
- bump `MINOR` for backward-compatible features
- bump `PATCH` for backward-compatible fixes

Until the interface is considered stable, `0.x` releases are expected.

## Before Releasing

Make sure the working tree is clean and review user-visible changes since the last release.

Update:

- `VERSION`
- `CHANGELOG.md`
- `README.md` or docs if behavior changed

Validate the project before tagging. CI should stay green, and local checks are still useful before cutting a tag:

- GitHub Actions CI is green on the release commit
- PowerShell syntax check and a basic `status` or `backup -DryRun` when testing locally
- Bash syntax check and a basic `status` or `backup --dry-run` when testing locally
- config example still matches the documented schema

Suggested manual commands:

```bash
bash -n runners/restic-batch-backup.sh
CONFIG_PATH="${XDG_CONFIG_HOME:-$HOME/.config}/restic-batch-backup/config.json"
./runners/restic-batch-backup.sh status --config "$CONFIG_PATH"
./runners/restic-batch-backup.sh backup --dry-run --config "$CONFIG_PATH"
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\runners\restic-batch-backup.ps1 -Action status -ConfigPath "$env:APPDATA\restic-batch-backup\config.json"
powershell -NoProfile -ExecutionPolicy Bypass -File .\runners\restic-batch-backup.ps1 -Action backup -DryRun -ConfigPath "$env:APPDATA\restic-batch-backup\config.json"
```

## Release Steps

1. Confirm the release version in `VERSION`.
2. Move relevant entries from `## [Unreleased]` into a new dated section such as `## [0.1.0] - YYYY-MM-DD`.
3. Commit the release preparation changes.
4. Create an annotated tag:

```bash
git tag -a vX.Y.Z -m "Release vX.Y.Z"
```

5. Push the branch and the tag:

```bash
git push origin main
git push origin vX.Y.Z
```

6. Let the GitHub Actions release workflow create the GitHub release from the tag.

The release workflow enforces two checks:

- the pushed tag must match `VERSION`
- `CHANGELOG.md` must contain a dated section for that exact version

The current release workflow publishes the repository contents as a GitHub release. Users should install from that release archive using `docs/INSTALLING_A_RELEASE.md`.

## After Releasing

Prepare the next development cycle:

- add new entries under `## [Unreleased]`
- bump `VERSION` when you decide the next target release number

## Notes

- Avoid releasing directly from unreviewed local changes.
- If a change affects restore behavior, retention, or config keys, call it out explicitly in the changelog.
- Treat a green CI run as a release requirement.
