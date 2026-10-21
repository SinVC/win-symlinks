# Release Pipeline

The install command always fetches the installer from the latest release:

```powershell
irm https://github.com/winddxr/win-symlinks/releases/latest/download/install.ps1 | iex
```

The installer queries the latest release on each online run, then downloads and
verifies the version-specific ZIP. Ordinary tags such as `v0.0.4` are published
as Latest. Explicit prerelease tags such as `v0.1.0-beta.1` do not replace Latest.
Existing prereleases are not reclassified automatically. The public installer
URL starts working after the first ordinary release containing `install.ps1`.

## Build Once, Publish The Verified Assets

`.github/workflows/ci.yml` handles both pull requests/main pushes and reusable
workflow calls from `.github/workflows/release.yml`:

1. Validate the requested tag against the `win-symlinks` Cargo package version.
2. Run formatting, Clippy across all workspace targets, Rust tests, and installer
   tests under Windows PowerShell 5.1 and PowerShell 7.
3. Build with `Cargo.lock` enforced, then test and produce the release packages.
4. For release calls, upload the four completed files as a single workflow artifact.
5. The publish job downloads that artifact and publishes it without rebuilding.

Only the publish job has `contents: write`; the Windows build job has read access.
PR updates cancel superseded CI runs. Release runs are serialized per tag and
are not canceled while publishing. The v3 release action uploads ordinary release
assets before publishing, so Latest is not switched to a partially uploaded package.
The action generates release notes using `.github/release.yml`.

## Release Assets

| File | Contents |
| --- | --- |
| `win-symlinks-v<VERSION>-x86_64-windows.zip` | Three executables and offline-capable `install.ps1` at ZIP root |
| `win-symlinks-broker-v<VERSION>-x86_64-windows.zip` | Broker executable, install/uninstall scripts and runtime README |
| `install.ps1` | Online installer used by the permanent Latest URL |
| `checksums-sha256.txt` | SHA-256 checksums for both ZIPs and the installer |

`scripts/package-release.ps1` owns the asset layout. It validates source files
and both CLI `--version` outputs before creating archives. It writes only the four
named assets; an output directory containing unrelated or older-version files is
rejected instead of recursively deleted or accidentally included in a release.
Repacking the same version into the same directory is supported.

## Local Verification And Publication

Update `crates/win-symlinks/Cargo.toml` to the intended version and update
`Cargo.lock` with Cargo. Update the client crate version when appropriate; its
version is independent of the application release guard.

```powershell
cargo fmt -- --check
cargo clippy --locked --workspace --all-targets -- -D warnings
cargo test --locked --workspace
powershell -NoProfile -ExecutionPolicy Bypass -File tests/install.Tests.ps1
pwsh -NoProfile -File tests/install.Tests.ps1
cargo build --locked --release --workspace
pwsh -NoProfile -File tests/package-release.Tests.ps1
.\scripts\package-release.ps1 -Version v<VERSION>
```

The default output is `dist/`. To keep packages for multiple versions locally,
pass a separate `-OutputDir` for each version. `-ValidateOnly` checks the tag and
manifest version without requiring built binaries or producing output.

Commit the changes, then push `v<VERSION>` on the intended commit. The tag starts
the full validation/build/package/publish workflow. A tag/manifest mismatch,
failed test, wrong CLI version, missing asset, or packaging error prevents the
publish job from running. Use a new tag for a new version; do not move published
version tags. Workflow artifact retention is seven days; a later retry needs a
fresh build if its artifact has expired.

An ordinary release completes bootstrap acceptance only after its public Latest
URL has been checked and the Windows UAC/service installation scenarios in
`design-testing-qa.md` have passed. Local checks do not exercise hosted Actions,
release permissions, or actual publication.
