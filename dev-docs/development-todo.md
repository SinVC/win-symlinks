# Development TODO

This TODO breaks implementation into bounded stages to keep agent context small and verification clear. Do not mark a stage complete until its listed verification passes.

## Stage 1 - CLI And Data Model

Goal: stabilize command parsing, shared errors, and IPC payload contracts before Windows-specific implementation begins.

- [x] Add focused tests for `ln -s TARGET LINK_NAME`, `ln -sf TARGET LINK_NAME`, `ln -sT TARGET LINK_NAME`, and `--win-kind=file|dir`.
- [x] Reject unsupported hardlink-style `ln TARGET LINK_NAME` with `UNSUPPORTED_MODE`.
- [x] Keep `ln.exe --help` and `ln.exe --version` service-free.
- [x] Finalize JSON request/response schema in `src/ipc`.
- [x] Add round-trip serialization tests for broker request/response payloads.
- [x] Ensure `ErrorCode` display strings match the documented script-friendly names.

Verification:

```powershell
cargo fmt -- --check
cargo test
cargo check
```

## Stage 2 - Path Policy And Symlink Semantics

Goal: complete pure logic before any privileged broker path exists.

- [x] Complete path normalization for drive paths, supported `\\?\` forms, suspicious UNC forms, short-name handling where practical, and malformed native paths.
- [x] Reject ADS-style `link_path` inputs after accounting for drive-letter colons.
- [x] Reject or canonicalize trailing-space and trailing-dot path spellings.
- [x] Implement default source blacklist generation from actual system locations where possible.
- [x] Add user blacklist merge logic without allowing user config to replace built-ins.
- [x] Implement component-aware blacklist matching, including volume roots and UNC administrative shares.
- [x] Decide target kind from filesystem state, with `--win-kind` as a hint for missing targets.
- [x] Model safe replacement rules for `ln -sf`: only existing symbolic links may be replaced.

Verification:

```powershell
cargo fmt -- --check
cargo test
cargo check
```

## Stage 3 - Direct True Symlink Creation

Goal: implement the unprivileged/direct path while preserving the same true symlink semantics as the broker path.

- [x] Wrap `CreateSymbolicLinkW` in `src/symlink`.
- [x] Use `SYMBOLIC_LINK_FLAG_DIRECTORY` for directory symlinks.
- [x] Use `SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE` only for direct client attempts.
- [x] Distinguish privilege failure from other create failures.
- [x] Return `TARGET_KIND_REQUIRED`, `LINK_ALREADY_EXISTS`, `TARGET_KIND_CONFLICT`, and `CREATE_SYMLINK_FAILED` as appropriate.
- [x] Confirm direct creation never falls back to junctions, hardlinks, copies, or `.lnk` files.

Verification:

```powershell
cargo fmt -- --check
cargo test
cargo check
```

Manual Windows verification should confirm created filesystem objects are true symbolic links.

## Stage 4 - Management Command And Service Registration

Goal: make `win-symlinks.exe` manage `WinSymlinksBroker` without putting management behavior in `ln.exe`.

- [x] Implement `service install` with `CreateServiceW`.
- [x] Configure service name `WinSymlinksBroker`, display name `Win Symlinks Broker`, `LocalSystem`, and delayed automatic start.
- [x] Implement `service uninstall`, stopping first when needed.
- [x] Implement `service start`, `service stop`, and `service status`.
- [x] Keep administrator-required failures clear.
- [x] Implement `config show` with effective built-in and user blacklist entries.

Verification:

```powershell
cargo fmt -- --check
cargo test
cargo check
```

Manual administrator-shell verification is required for install/start/status/stop/uninstall.

## Stage 5 - Broker IPC

Goal: connect `ln.exe` to the broker over local Named Pipe IPC with stable JSON payloads and timeouts.

- [x] Implement Named Pipe server at `\\.\pipe\win-symlinks-broker`.
- [x] Create the pipe from the broker service only.
- [x] Use `PIPE_REJECT_REMOTE_CLIENTS`.
- [x] Apply an explicit DACL granting only the documented local principals and minimum client read/write access.
- [x] Implement client connection timeout of 3 seconds and request timeout of 30 seconds.
- [x] Verify connected server process identity before sending privileged requests.
- [x] Return `SERVICE_IDENTITY_MISMATCH` if the pipe server is not the installed broker service process.
- [x] Serialize filesystem mutation processing in the broker.

Verification:

```powershell
cargo fmt -- --check
cargo test
cargo check
```

Manual or integration verification must include unavailable service and wrong-server pipe scenarios.

## Stage 6 - Broker Security Validation

Goal: enforce the broker security contract before privileged symlink creation.

- [x] Validate request schema and protocol version.
- [x] Impersonate the Named Pipe client and identify a concrete local user SID.
- [x] Reject remote, anonymous, and network logon clients.
- [x] Normalize `link_path` and `target_path` before policy checks.
- [x] Enforce the source blacklist against normalized `link_path`.
- [x] While impersonating the caller, verify write/create permission on the `link_path` parent directory.
- [x] Re-check safe replacement conditions immediately before deletion.
- [x] Return to the service token before calling privileged `CreateSymbolicLinkW`.
- [x] Write audit log entries for successful privileged operations.

Verification:

```powershell
cargo fmt -- --check
cargo test
cargo check
```

Manual security verification must cover denied parent permissions, blacklisted paths, and replacement refusal for real files/directories/junctions.

## Stage 7 - End-To-End Acceptance

Goal: prove the user workflow works under the intended Windows 11 conditions.

- [x] From an administrator shell: install and start the service.
- [x] From a non-admin shell with Developer Mode disabled: create file and directory symlinks through `ln.exe`.
- [x] Create missing-target links with `--win-kind=file` and `--win-kind=dir`.
- [x] Replace an existing symlink with `ln -sf`.
- [x] Confirm `ln -sf` refuses to replace real files and real directories.
- [x] Confirm created objects are symbolic links, not junctions, hardlinks, file copies, directory copies, or `.lnk` shortcuts.
- [x] Run `win-symlinks.exe doctor`.
- [x] Uninstall the service from an administrator shell.

Manual acceptance completed on Windows 11 with Developer Mode disabled. Doctor still reports remote-client rejection and Named Pipe DACL inspection as manual external security checks.

Verification:

```powershell
cargo fmt -- --check
cargo test
cargo check
```

Record any manual-only acceptance gaps in the final handoff for the stage.

## Stage 8 - One-Line Binary Installation

Goal: install and upgrade published binaries using a single PowerShell command.

- [x] Add an `irm ... | iex` bootstrap with automatic UAC and error propagation.
- [x] Resolve stable/prerelease-only releases and support a pinned binary version.
- [x] Verify SHA-256 before extracting only the three required executables.
- [x] Protect the LocalSystem binary directory and refuse another broker installation.
- [x] Support repeat installation, upgrade rollback, and offline full ZIP installation.
- [x] Configure Machine/current-terminal PATH and report command conflicts.
- [x] Publish the script and its checksum alongside release ZIP assets.
- [x] Use the latest Release installer URL and promote normal `v0.x.y` tags to Latest.
- [x] Add PowerShell 5.1/7 installer verification to CI and release workflows.
- [x] Document the one-line install and upgrade in English and Chinese.
- [x] Pass formatting, Rust test/build checks, and the PowerShell 5.1/7 harness.
- [ ] Complete manual Windows installer acceptance.

Verification:

```powershell
cargo fmt -- --check
cargo test
cargo check
powershell -NoProfile -ExecutionPolicy Bypass -File tests/install.Tests.ps1
pwsh -NoProfile -File tests/install.Tests.ps1
```

Manual acceptance: use the bootstrap scenarios in `design-testing-qa.md` on an
x64 Windows 11 test machine. Mocked SCM/UAC tests alone do not complete this stage.

Automatic verification recorded on 2026-10-21: formatting, all 51 Rust unit
tests and `cargo check` passed; all 28 installer scenarios passed under both
Windows PowerShell 5.1 and PowerShell 7. Live GitHub resolution selected v0.0.3,
and download, SHA-256 verification, extraction and both CLI `--version` checks
passed in both shells without changing the installed broker or Machine PATH.
Actual UAC, protected Program Files ACLs and SCM install/upgrade acceptance are
still pending. The documented public URL requires a new non-prerelease containing
`install.ps1` to be published with the updated workflow; merging to `main` alone
does not activate the download endpoint.

## Stage 9 - Release Workflow Maintenance

Goal: share CI validation and publish the exact assets produced by the verified build.

- [x] Reuse CI from the tag workflow instead of duplicating validation/build steps.
- [x] Extract release packaging into a locally runnable PowerShell script.
- [x] Validate tag/Cargo/binary versions and enforce locked Cargo dependencies.
- [x] Preserve ZIP layouts, asset names, standalone installer and checksum format.
- [x] Limit release write permissions to the publish job and pass built assets as an artifact.
- [x] Add real ZIP/content/checksum and packaging-failure tests.
- [x] Complete local formatting, test, check and packaging verification.
- [ ] Verify a real tag run and the public Latest installer URL after publication.

See `releasing.md` for the workflow, local commands, release procedure and limits.

Automatic verification recorded on 2026-10-21: formatting, Clippy, all 51 Rust
tests, `cargo check` and the release build passed. All 29 installer scenarios
passed in Windows PowerShell 5.1 and PowerShell 7; all 7 packaging scenarios
passed against the release binaries. Both workflows passed actionlint, and
local v0.0.3 packaging produced the four expected release assets. Hosted tag
execution, publication and manual installer acceptance remain pending.

Release v0.0.4 preparation on 2026-10-21 repeated all of the above local checks
successfully with both workspace packages at 0.0.4 and produced the four expected
assets under `dist/v0.0.4`.
