# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project aims to follow Semantic Versioning.

## [0.1.0] - 2026-06-21

### Added

- Windows PowerShell runner for config-driven Restic batch backups.
- Linux Bash runner with matching core actions and safety checks.
- Shared JSON configuration example and project documentation.
- Initial release management files: `VERSION`, `CHANGELOG.md`, and `docs/RELEASING.md`.
- GitHub Actions CI workflow for Bash and PowerShell linting, syntax checks, and smoke tests.
- Tag-driven GitHub release workflow that validates `VERSION` and uses `CHANGELOG.md` release notes.
- Optional `ssh.identityFile` support for SFTP repositories in both runners.
- Committed example configs now live under `config_examples/` with more descriptive filenames.
- Test data generator now supports `--target` and `--mutate` options for SFTP backup testing.
- Added dedicated SFTP server setup documentation for provisioning restricted backup users.
