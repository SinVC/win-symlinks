# Testing & QA Plan (win-symlinks)

This document outlines the testing strategy, acceptance criteria, and manual verification scenarios for the `win-symlinks` project.

## Test Plan

### Unit Tests

- Parse `ln -s TARGET LINK_NAME`.
- Parse `ln -sf TARGET LINK_NAME`.
- Parse `ln -sT TARGET LINK_NAME`.
- Reject unsupported hardlink-style `ln TARGET LINK_NAME`.
- Normalize paths before blacklist matching.
- Match blacklisted prefixes by path component.
- Do not match sibling prefixes such as `C:\WindowsTools` for `C:\Windows`.
- Reject malformed native paths and suspicious UNC administrative shares.
- Reject ADS-style `link_path` inputs.
- Canonicalize or reject `\\?\` long-path inputs before blacklist matching.
- Require target kind when target is missing and cannot be inferred.
- Detect `TARGET_KIND_CONFLICT` when the broker's final target-kind decision conflicts with the CLI hint.

### Integration Tests

- Create a true file symlink through the broker.
- Create a true directory symlink through the broker.
- Confirm created objects are symbolic links, not junctions or hardlinks.
- Confirm `ln -sf` replaces an existing symbolic link.
- Confirm `ln -sf` refuses to replace a real file.
- Confirm `ln -sf` refuses to replace a real directory.
- Confirm deletion removes only the symbolic link and leaves the target intact.
- Confirm source blacklist blocks protected paths.
- Confirm source blacklist blocks ADS and long-path bypass attempts.
- Confirm the broker rejects remote Named Pipe clients.
- Confirm the Named Pipe DACL does not allow anonymous, `Everyone`, or network logon access.
- Confirm the client rejects a pipe server that does not match the installed `WinSymlinksBroker` service.
- Confirm a caller cannot create a symlink in a parent directory where that caller lacks create/write permission.
- Confirm concurrent requests for the same `link_path` are serialized and the second request observes the final state.
- Confirm service unavailable errors are clear when broker is not installed.
- Confirm `doctor` reports the resolved `ln.exe` path.

### Manual Acceptance Scenarios

First run from an administrator shell on Windows 11:

```text
win-symlinks.exe service install
win-symlinks.exe service status
```

Then run from a non-admin shell with Developer Mode disabled:

```text
ln -s target.txt link.txt
ln -s target-dir link-dir
ln -s --win-kind=file future-target.txt future-link.txt
ln -sf target2.txt link.txt
win-symlinks.exe doctor
```

Finally run from an administrator shell:

```text
win-symlinks.exe service uninstall
```

Expected result:

- Service installation requires administrator approval.
- Once installed, non-admin `ln -s` can create real symbolic links.
- The implementation never creates junctions, hardlinks, copies, or `.lnk` files.

## Acceptance Criteria

### PowerShell Bootstrap Verification

Run the dependency-free installer harness under both supported shells:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/install.Tests.ps1
pwsh -NoProfile -File tests/install.Tests.ps1
```

It exercises real file copying, ZIP extraction, checksum verification and rollback,
with SCM, downloads, Machine PATH and UAC replaced by controlled test doubles.
The elevation child protocol is exercised in a real unelevated PowerShell process
using harmless payloads, including argument quoting and source tampering.
These tests do not install or change a developer's broker service.

Before releasing the bootstrap, verify on an x64 Windows 11 test machine:

- Run the documented `irm ... | iex` from both PowerShell 5.1 and 7 in a normal
  terminal; accept UAC and verify service registration, restricted installation
  ACLs, PATH in that terminal, and true file/directory symlinks from a normal user.
- Cancel UAC and confirm a visible error and no installed service or PATH change.
- Rerun to upgrade an existing installation. Verify a locked CLI binary causes
  rollback, the service still runs, and unrelated config/audit files are preserved.
- Confirm a broker installed elsewhere is refused without changing its registration.
- Install the verified extracted full ZIP without network access.
- Confirm mismatched checksums and unsupported architectures stop before binary
  replacement or service changes. Inspect other terminal instances for PATH refresh.

Actual UAC approval, protected Program Files ACLs, SCM changes, and non-admin
symbolic link creation remain manual acceptance checks beyond the harness.

### Release Packaging Verification

After `cargo build --locked --release --workspace`, run
`pwsh -NoProfile -File tests/package-release.Tests.ps1`.
This uses the real built executables to verify ZIP root layouts, entry contents,
standalone installer identity, and checksum compatibility with the installer.
It also checks rejection of wrong tags, missing or incorrect binaries, and stale
output files, plus safe repeat packaging. It never publishes a GitHub release.

CI and the tag workflow share these checks. Hosted workflow execution, artifact
transfer, Release publication and the public Latest URL still require a real tag
run; see `releasing.md` for the procedure.

- The design document exists at `docs/windows-symlink-broker-design.md`. (Note: originally as a single document, now split into multiple focused documents).
- The project is consistently named `win-symlinks`.
- `ln.exe` is the Linux-compatible command name.
- `win-symlinks.exe` is the management command name.
- `WinSymlinksBroker` is the Windows Service name.
- The document clearly states that command names and service names do not need to match.
- The document clearly states that service installation can be done without an installer package but still requires administrator rights.
- The document clearly states that source uses a blacklist policy.
- The document clearly states that only real symbolic links are supported.
- The document defines the service account as `LocalSystem`.
- The document requires local-only Named Pipe IPC and explicit pipe DACL.
- The document requires caller identity validation and caller parent-directory write authorization.
- The document documents blacklist limitations, ADS handling, long-path handling, and TOCTOU limits.
- The document includes Rust crate recommendations.
- The document includes test cases for true symlink creation and refusal of fallback object types.
