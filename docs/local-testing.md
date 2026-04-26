# Local testing workflow

Iterate on install / uninstall / detect scripts against a lab VM
**without** going through the Intune build-upload-assign-wait loop every
time.

`Build\Build-IntuneWinPackages.ps1` is a two-phase pipeline:

1. **Staging** (always runs): assembles each product into a
   self-contained folder at `Build\Staging\<Product>\`. That folder
   is **bit-for-bit the layout Intune extracts on a client** when it
   delivers the matching `.intunewin`.
2. **Packaging** (default; skipped with `-StagingOnly`): runs
   `IntuneWinAppUtil.exe` on each staged folder and writes the
   resulting `.intunewin` plus a `<Product>-IntuneConfig.md` to
   `Build\Output\<Product>\`.

Because both phases share the same staging code, anything that runs
from `Build\Staging\<Product>\` on a lab VM will behave identically
after a real Intune deployment.

> ℹ️ The staged XMLs are **post-token-substitution**. If you pass
> `-CompanyName "Contoso"` (or set it in `build-config.json`), the
> staged XML carries `Value="Contoso"`. If you don't, the
> `<Setup Name="Company" .../>` line is removed from the staged XML
> entirely. Lab VMs see exactly what production devices would.

## When to use this vs. going through Intune

| Use `Build\Staging\` locally when                        | Go through Intune when                        |
|----------------------------------------------------------|------------------------------------------------|
| Debugging a script, an exit code, or detection logic     | Verifying ESP timing, group assignments, ring |
| Confirming a new config XML before broad rollout         | Testing the upload-and-assign pipeline         |
| Reproducing a failure with CMTrace open side-by-side     | Validating MDM policy interactions             |
| Iterating fast (seconds per cycle)                       | Final smoke-test before a production rollout  |

## Prerequisites

- Lab Windows 10/11 VM you can snapshot freely. Avoid testing on
  anything that matters — the scripts change the machine's Office
  install state.
- `Source\setup.exe` in place (see [`../README.md`](../README.md#1-setupexe--office-deployment-tool))
  or plan to pass `-SetupExeSource ''` and rely on per-product copies.
- A way to get files onto the VM: shared folder, `scp`, an RDP
  clipboard copy, or mounting the VHD. Whatever you use on the rest
  of your lab.

## Produce the staged folders

### Staging-only (fast path — just what you need for a lab VM)

From the repository root on your dev machine:

```powershell
.\Build\Build-IntuneWinPackages.ps1 -StagingOnly
```

No `.intunewin` is produced, no `IntuneWinAppUtil.exe` is invoked —
just the staged trees land at:

```
Build\Staging\
├── M365Apps\
│   ├── Install-M365Apps.ps1
│   ├── Uninstall-M365Apps.ps1
│   ├── Detect-M365Apps.ps1
│   ├── Configurations\*.xml
│   ├── Tools\setup.exe
│   └── Common\*.psm1
├── Visio\           (same shape)
├── Project\
└── LanguagePacks\
```

Each folder is self-contained — scripts, Configurations\, bundled
setup.exe, Common\ modules. That is exactly what the Intune
Management Extension hands off to your install command when it
extracts a `.intunewin` in production.

### Full build (also produces `.intunewin` artefacts)

```powershell
.\Build\Build-IntuneWinPackages.ps1
```

Staging is retained alongside the `Build\Output\<Product>\*.intunewin`
files by default, so you can do a full build once and then iterate on
the staged copies. Pass `-CleanStaging` to wipe `Build\Staging\` at
the end if you want to save disk space.

## Iterate on the VM

### 1. Snapshot the VM

Take a clean snapshot from a known good state (fresh Autopilot,
AAD-joined, no Office installed). Name it something like
`clean-nooffice`.

### 2. Copy the staged folder over

From the host, using a shared folder (example assumes a mapped share
at `\\vmname\c$\Temp\`):

```powershell
Copy-Item -Path .\Build\Staging\M365Apps `
          -Destination \\vmname\c$\Temp\ -Recurse
```

### 3. Run the install elevated

From an elevated PowerShell prompt **on the VM** (or over PS
Remoting):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File C:\Temp\M365Apps\Install-M365Apps.ps1
echo "Install exit: $LASTEXITCODE"
```

### 4. Watch the log

In another window on the VM:

```powershell
Get-ChildItem C:\ProgramData\M365AppsDeploy\Logs\ |
    Sort-Object LastWriteTime -Descending
# Open the most recent product log (e.g. M365Apps-Install.log) in
# CMTrace or OneTrace.
```

### 5. Verify detection

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File C:\Temp\M365Apps\Detect-M365Apps.ps1
echo "Detect exit: $LASTEXITCODE"    # 0 = installed, 1 = not installed
```

### 6. Revert the snapshot and iterate

Back on the host, revert via your hypervisor's snapshot mechanism
(`Restore-VMSnapshot` for Hyper-V, etc.), then repeat from step 2.

Each iteration is snapshot → copy → run → inspect → revert. No
Intune round-trip, no waiting for ESP, no content delivery delays.

## Running the end-to-end harness against the staged layout

`Tests\Invoke-DeploymentTest.ps1` can drive the full install → detect
→ uninstall lifecycle against either the repo tree or the staged
layout. Pass `-FromLocalBuild` to point at `Build\Staging\`:

```powershell
# Run against the repo tree (default):
.\Tests\Invoke-DeploymentTest.ps1 -UseEvergreenSetup

# Run against the staged layout (stage it first):
.\Build\Build-IntuneWinPackages.ps1 -StagingOnly
.\Tests\Invoke-DeploymentTest.ps1 -FromLocalBuild
```

With `-FromLocalBuild`, every step in the harness invokes
`Build\Staging\<Product>\<Script>.ps1` instead of the repo-root
equivalent. This validates that the staged layout behaves
identically to the repo-tree layout — the test that would otherwise
require a full Intune deployment.

Point at a custom location with `-LocalBuildPath <path>` if you
copied the staging somewhere else.

## Cleaning up

The staging folder is reproducible — delete it freely:

```powershell
Remove-Item -Path .\Build\Staging -Recurse -Force
```

Re-run `Build-IntuneWinPackages.ps1 -StagingOnly` to rebuild. Each
invocation cleans the target product folder before re-staging, so
partial updates don't leave orphan files behind.

Or pass `-CleanStaging` on the next full build to wipe `Build\Staging\`
automatically:

```powershell
.\Build\Build-IntuneWinPackages.ps1 -CleanStaging
```

## Troubleshooting

### Install fails with "ODTLogging module not found"

The Install/Uninstall scripts probe for `Common/` at
`$PSScriptRoot\Common` first, then fall back to
`$PSScriptRoot\..\Common`. If both fail:

- Confirm `Build\Staging\<Product>\Common\*.psm1` exists (the staging
  step should have created it — re-run the build script).
- If you copied only `Install-*.ps1` to the VM instead of the whole
  `<Product>\` folder, copy the entire folder.

### Detection script fails with "LanguageID parameter missing"

Intune does not pass parameters to detection scripts. For Language
Packs the staged folder under `Build\Staging\LanguagePacks\` contains
the generic `Detect-LanguagePack.ps1` (which still takes parameters,
useful for ad-hoc testing). For an Intune upload, use the
auto-generated per-language wrappers under
`Build\Output\LanguagePacks\DetectionScripts\Detect-LanguagePack-<lang>.ps1`
— each wrapper has its `LanguageID` hard-coded. See
[`intune-deployment.md`](intune-deployment.md#detection-script-parameters--auto-generated-wrappers).

### Scripts exit 1603 immediately

Check elevation. Prerequisite checks refuse to run if the shell is
not elevated. For quick-and-dirty iteration you can pass
`-SkipPrerequisiteChecks` to the Install/Uninstall scripts, but
don't rely on that in production paths.
