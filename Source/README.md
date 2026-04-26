# Source/ — shared build inputs

`Source\` is the shared inputs folder used by
`Build\Build-IntuneWinPackages.ps1`. Drop binaries here that the
build pipeline needs to stage into multiple product packages.

The folder's contents are **gitignored** by design — `Source\setup.exe`
is excluded by the `.gitignore` entry `Source/setup.exe`, so the
Microsoft binary is never committed. Only this README and
`Update-Tooling.ps1` are committed (they explain what should sit
here and how to fetch it). Building a fresh fork starts with
placing your downloaded `setup.exe` at `Source\setup.exe` once —
either by hand or via the helper script described below.

## Recommended: `Update-Tooling.ps1`

Run this once on a fresh clone, and again whenever you want to
refresh the toolchain. From a PowerShell prompt at the repo root:

```powershell
.\Source\Update-Tooling.ps1
```

What it does:

- Downloads `setup.exe` (Office Deployment Tool) from
  `https://officecdn.microsoft.com/pr/wsus/setup.exe` — the same
  URL the install scripts' `-UseEvergreenSetup` runtime path
  uses.
- Downloads `IntuneWinAppUtil.exe` from the latest release at
  microsoft/Microsoft-Win32-Content-Prep-Tool on GitHub.
- **Authenticode-verifies both binaries before placement.** Rejects
  anything where the signature status isn't `Valid` or the signer
  subject isn't Microsoft Corporation. A bad download cannot
  half-overwrite a good existing copy.
- Places `setup.exe` at `Source\setup.exe` and `IntuneWinAppUtil.exe`
  at `Build\IntuneWinAppUtil.exe`.
- Writes `Source\tooling-versions.json` (gitignored) recording
  version + source URL + downloaded-at timestamp for each binary.

Idempotent in the always-fetch sense: every run re-downloads both
binaries. There is no "skip if current" comparison. ~10 MB / run.

The script never runs from inside the build pipeline. The build
itself is **network-free** — it expects the binaries to already be
in place at their canonical locations. See
[`docs/architecture.md`](../docs/architecture.md) "6. Bundled
setup.exe by default, evergreen optional" for the rationale.

## Manual alternative

If you'd rather fetch the binaries by hand (no network access from
the build host, an audit policy that rejects scripted downloads,
etc.), the manual flow still works:

### `setup.exe` — Office Deployment Tool

Download from Microsoft Download Center:
<https://www.microsoft.com/en-us/download/details.aspx?id=49117>

Extract `setup.exe` from the installer and place it at
`Source\setup.exe`. `Build\Build-IntuneWinPackages.ps1` will stage it
into every product's `Tools\` folder at build time, so the resulting
`.intunewin` packages each carry a copy.

### `IntuneWinAppUtil.exe` — Win32 Content Prep Tool

Download from <https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool>
and place at `Build\IntuneWinAppUtil.exe`. Verify with
`Get-AuthenticodeSignature` if you're not using `Update-Tooling.ps1`.

## Per-product override

If a specific product needs a **different** `setup.exe` (e.g. an older
ODT build to reproduce a deployment), drop that binary into the
product's own `Tools\` folder **and** pass `-SetupExeSource ''` to the
build script. Per-product binaries are left alone when no source is
configured.

## Why not check it in?

- Microsoft's license terms say "redistribute, but unmodified and with
  the license" — simpler to not ship Microsoft binaries at all and have
  admins fetch fresh copies on their own cadence.
- ODT updates regularly. Anchoring the repo to a specific version would
  mean stale code within weeks.
