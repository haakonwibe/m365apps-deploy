# Intune deployment guide

Step-by-step procedure for uploading each product from this toolkit to
Microsoft Intune as a Win32 app. Follow top-to-bottom; the order matters
because Visio and Project depend on M365 Apps being deployed first.

## Prerequisites

- Intune tenant with Win32 app delivery enabled
- Windows 10/11 Enterprise or Pro, 64-bit target devices
- Devices enrolled via Autopilot or direct MDM
- `IntuneWinAppUtil.exe` downloaded and placed at `Build\IntuneWinAppUtil.exe`
- `setup.exe` downloaded and placed at `Source\setup.exe` (one copy,
  shared across all products — the build script stages it into each
  product's `Tools\` folder automatically), OR plan to always pass
  `-UseEvergreenSetup` on the install commands

## Step 1: Build the `.intunewin` packages

From the repo root:

```powershell
.\Build\Build-IntuneWinPackages.ps1
```

Two folders are populated:

| Folder                                  | Contents                                                         |
|-----------------------------------------|------------------------------------------------------------------|
| `Build\Staging\<Product>\`              | Self-contained staged tree (scripts + Configurations\ + Tools\ + Common\). Retained on disk so you can copy it to a lab VM for iterative testing — see `docs\local-testing.md`. |
| `Build\Output\<Product>\*.intunewin`    | The Win32 package to upload to Intune.                           |
| `Build\Output\<Product>\DetectionScripts\` | Per-product detection scripts ready to upload as the Intune custom detection script. Simple products (M365Apps / Visio / Project): one `Detect-<Product>.ps1` copied verbatim from staging. LanguagePacks: one self-contained `Detect-LanguagePack-<LanguageID>.ps1` per supported Office language, with the language ID baked in (Intune does not pass parameters to detection scripts). |
| `Build\Output\<Product>\<Product>-IntuneConfig.md` | Auto-generated cheat-sheet with the exact install / uninstall / detection / dependency / return-code values to paste into the Intune Win32 app UI. |

By default, the build script stages `Source\setup.exe` into every
product's `Tools\` folder before packaging. If `Source\setup.exe` is
missing, the script warns per-product and falls back to whatever
`<Product>\Tools\setup.exe` is already in place — or, if nothing is
there, to `-UseEvergreenSetup` at deploy time.

Options:

```powershell
# Stage only - skip IntuneWinAppUtil (use for lab testing):
.\Build\Build-IntuneWinPackages.ps1 -StagingOnly

# Full build, then wipe Build\Staging\ at the end:
.\Build\Build-IntuneWinPackages.ps1 -CleanStaging

# Per-product setup.exe overrides (no shared Source\setup.exe):
.\Build\Build-IntuneWinPackages.ps1 -SetupExeSource ''
```

Once the build completes, open `Build\Output\<Product>\<Product>-IntuneConfig.md`
next to each `.intunewin` — it contains the exact values that map
1:1 to Intune's Win32 app upload wizard. The manual steps below
still apply, but the cheat-sheets remove the need to memorise
command strings and return-code tables.

> 💡 If you want to bake an org-specific value (today: `CompanyName`)
> into the staged XMLs, run the build with `-CompanyName "Contoso"`
> or persist it in `build-config.json`. See the
> [Optional build parameters](../README.md#️-optional-build-parameters)
> section in the README and
> [Section 4 of the customization guide](customization.md#4-org-specific-values-via-build-time-tokens).

## Step 2: Upload M365 Apps first

In the Microsoft Intune admin center
(<https://intune.microsoft.com>) → **Apps** → **Windows** → **+ Add** →
**Windows app (Win32)**.

1. **App package file**: `Build\Output\M365Apps\Install-M365Apps.intunewin`
2. **Name**: `Microsoft 365 Apps for Enterprise`
3. **Publisher**: `Microsoft`
4. **Description**: copy the description from Microsoft's page, or write
   a brief in-house description.
5. **Install command**:
   ```
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File Install-M365Apps.ps1
   ```
6. **Uninstall command** (surgical — keep this default):
   ```
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File Uninstall-M365Apps.ps1
   ```
   This removes only `O365ProPlusRetail` and any installed language
   packs. Visio and Project remain installed. **Do not add
   `-RemoveAll` here**: unassigning the Office app would silently rip
   Visio and Project off the device too. If you ever need a full
   Click-to-Run wipe for a device, run
   `Uninstall-M365Apps.ps1 -RemoveAll` manually or as a separate,
   explicitly-named Intune app. See
   [`architecture.md#uninstall-semantics`](architecture.md#uninstall-semantics).
7. **Install behaviour**: **System**
8. **Device restart behaviour**: **Determine behaviour based on return codes**
9. **Return codes**: leave the defaults (0, 1707 success; 3010 soft reboot;
   1641 hard reboot; 1618 retry). Add `17002` as a **failed** code so
   silent-failure detection in our scripts propagates correctly.
10. **Requirement rules**:
    - Operating system architecture: **64-bit**
    - Minimum OS: **Windows 10 21H2** (or your org's baseline)
11. **Detection rules**: **Use a custom detection script**
    - Script file: `Build\Output\M365Apps\DetectionScripts\Detect-M365Apps.ps1`
    - Run as 32-bit process on 64-bit clients: **No**
    - Enforce script signature check: **No** (enable if you sign your scripts)
12. **Assignments**: assign as **Required** to your "M365 Apps users"
    dynamic group.

## Step 3: Upload Visio (depends on M365 Apps)

Same procedure as above but:

- Package: `Build\Output\Visio\Install-Visio.intunewin`
- Name: `Microsoft Visio Professional`
- Install command:
  ```
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File Install-Visio.ps1
  ```
- Uninstall command:
  ```
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File Uninstall-Visio.ps1
  ```
- Detection script: `Build\Output\Visio\DetectionScripts\Detect-Visio.ps1`
- **Dependencies**: add **Microsoft 365 Apps for Enterprise** as a required
  dependency with **Automatically install**: **Yes**. This ensures Office
  is installed before Intune tries Visio.
- Assign to users/groups licensed for Visio.

## Step 4: Upload Project (depends on M365 Apps)

Identical to Visio but swap "Visio" → "Project":

- Package: `Build\Output\Project\Install-Project.intunewin`
- Name: `Microsoft Project Professional`
- Detection script: `Build\Output\Project\DetectionScripts\Detect-Project.ps1`
- Dependency on Microsoft 365 Apps for Enterprise
- Assign to Project-licensed users.

## Step 5: Upload Language Packs

Language packs need **one Win32 app per (language, product) pair** you
want to deploy. Example: if you need Norwegian for M365 Apps and German
for Visio, you'll create two Intune apps.

For each language/product combination:

- Package: `Build\Output\LanguagePacks\Install-LanguagePack.intunewin`
- Name: e.g. `M365 Apps - Norwegian Bokmål (nb-no)`
- Install command (substitute your values):
  ```
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File Install-LanguagePack.ps1 -LanguageID nb-no -TargetProduct O365ProPlusRetail
  ```
- Uninstall command:
  ```
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File Uninstall-LanguagePack.ps1 -LanguageID nb-no -TargetProduct O365ProPlusRetail
  ```
- Detection script file:
  `Build\Output\LanguagePacks\DetectionScripts\Detect-LanguagePack-<LanguageID>.ps1`
  - The build emits one self-contained wrapper per supported Office
    language (one Norwegian Bokmål script, one German script, …) with
    the language ID hard-coded. Intune does not pass parameters to
    custom detection scripts, so each Win32 app uploads the wrapper
    that matches its language.
  - The primary registry-key check (`LanguagePack - <lang>`) is
    product-agnostic, so the same wrapper works for Office, Visio,
    and Project language packs without per-product variants. If the
    deployment uses the alternate per-product key shape
    (`<TargetProduct> - <lang>`), open the wrapper and edit the
    hard-coded `$TargetProduct` value at the top.
- Dependency: **Microsoft 365 Apps for Enterprise** (or Visio / Project
  if this is a Visio / Project language pack)
- Assignment: target only users who need this specific language.

## Standalone Proofing Tools is not supported

If you need spell-check for a non-primary language, upload the full
**Language Pack** for that language (Step 5 above). Language Packs
include proofing as part of the package.

The toolkit does not ship a standalone `ProofingTools` product:
ODT's `Product ID="ProofingTools"` flow returns 0 and creates an
Uninstall registry entry, but Office's language UI does not
reliably recognise the proofing as installed. See
[`architecture.md`](architecture.md#standalone-proofing-tools-not-supported)
for the rationale.

## Install ordering during ESP

Intune **Win32 app dependencies** are how install order is enforced.
The Intune Management Extension (IME) walks the dependency graph from
leaf toward root: for each dependency it runs that dependency's
**detection script** to check whether it's already installed; if not,
it installs it first (when "Auto-install" is set to **Yes**); only
then does it move on to the dependent app. The detection-script
verdict is the gate — not the install command's exit code.

### Recommended dependency graph

| App                                | Required dependency             | Auto-install |
|------------------------------------|---------------------------------|--------------|
| Microsoft 365 Apps for Enterprise  | (none — root)                   | —            |
| Microsoft Project Professional     | M365 Apps for Enterprise        | Yes          |
| Microsoft Visio Professional       | M365 Apps for Enterprise        | Yes          |
| Language Pack for M365 Apps        | M365 Apps for Enterprise        | Yes          |
| Language Pack for Visio            | Microsoft Visio Professional    | Yes          |
| Language Pack for Project          | Microsoft Project Professional  | Yes          |

Set each dependency in the Win32 app's **Properties → Dependencies →
Add → pick the parent app → Auto-install: Yes**.

The toolkit's add-on install scripts also cross-check the base product
themselves (`Install-Visio.ps1` / `Install-Project.ps1` /
`Install-LanguagePack.ps1` throw a clear error if the base isn't
present). Misconfigured dependencies therefore produce an
Intune-visible failure rather than a silent broken state — but
properly configured dependencies eliminate the failure-and-retry
cycle and keep ESP time predictable.

### Sibling installs and ODT mutex

Project and Visio both depend on M365 Apps but not on each other.
Once M365 Apps detection passes, IME may attempt to install them
**in parallel**. Click-to-Run uses a global mutex for concurrent
operations:

- The losing install hits exit code **1618** ("Another install in
  progress").
- The Win32 app's "Return codes" table (cheat-sheet step 9) maps
  `1618` to **Retry**.
- IME retries on its own schedule (typically a few minutes later).
- Eventually both succeed.

This works but adds 5–10 minutes to total ESP install time. If your
ESP window is tight, chain the sibling dependencies — e.g. make Visio
depend on **Project** in addition to M365 Apps, so Visio waits until
Project is detected. The toolkit's add-on installs are functionally
independent of each other, so chaining is purely a deployment-timing
choice. Don't chain if you sometimes deploy Visio without Project —
the chained dependency would block Visio from ever installing on
Project-less devices.

### ESP gating: what to include and what not to

The ESP "Block device use until these required apps are installed"
list gates user sign-in. It does **not** itself enforce install
order between apps — that's what dependencies are for. To produce a
predictable first-sign-in experience:

- **Required + ESP-blocking**: M365 Apps for Enterprise. Users wait
  through this on first device sign-in (15–30 min for the payload
  alone).
- **Required, NOT ESP-blocking**: Visio, Project, Language Packs.
  These install in the background after the user signs in.
  Including them in the ESP blocking list multiplies the wait
  without helping anyone — the user can sign in to a usable desktop
  while Visio finishes in the background.
- **ESP timeout**: bump to **≥ 60 minutes** (Devices → Windows →
  Windows enrollment → Enrollment Status Page → pick your profile →
  Apps → "Block device use until these required apps are installed
  if they are assigned to the user/device"). 60 minutes covers the
  M365 Apps payload plus dependency-walk overhead with margin.

### What a healthy ESP run looks like in the IME log

```
1.  M365 Apps install command runs (≈ 15 min)
2.  M365 Apps install command exits 0
3.  M365 Apps detection runs → detected
4.  IME marks M365 Apps installed
5.  Project + Visio install commands kick off (potentially parallel)
6.  One wins the ODT mutex; the other returns 1618
7.  IME retries the loser on its schedule
8.  Both eventually exit 0; both detection scripts pass
9.  Language Pack install commands run after their parent's detection
10. All detection scripts pass; ESP unblocks
```

If a dependency's detection fails right after install (rare, but can
happen on slower disks where C2R registration lags), IME re-runs
**detection** on its own retry cadence — it does **not** re-run the
install command. The transient miss self-corrects without
re-installing. (See `docs/architecture.md` "Intune execution
environment" for the full IME behavioural model.)

## Detection script parameters — auto-generated wrappers

Intune's detection-script UI runs the script with no parameters. The
build pipeline solves this for LanguagePacks by emitting one
self-contained wrapper per supported Office language to
`Build\Output\LanguagePacks\DetectionScripts\Detect-LanguagePack-<LanguageID>.ps1`.
Each wrapper has its language ID hard-coded and is ready to upload as
the Intune custom detection script — no manual stubs required.

The wrapper bodies are derived verbatim from
`LanguagePacks\Detect-LanguagePack.ps1` at build time, so the detection
logic stays in one place. If you change the detection logic, run the
build to refresh every wrapper.

## Smoke-test before broad rollout

1. Enrol a single test device (or reset an existing one) into the pilot
   group.
2. Watch `C:\ProgramData\M365AppsDeploy\Logs\M365Apps-Install.log` from a
   separate RDP session, filtered through CMTrace.
3. Confirm detection returns **installed** after Intune reports success:
   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Path\To\Detect-M365Apps.ps1
   echo $LASTEXITCODE
   ```
4. Repeat for Visio, Project, and language pack if deployed.
5. Reset the VM and run again to confirm reproducibility.

## Common pitfalls checklist

- [ ] `setup.exe` present in each product's `Tools\` folder (or
  `-UseEvergreenSetup` configured consistently)
- [ ] `IntuneWinAppUtil.exe` at `Build\IntuneWinAppUtil.exe`
- [ ] Each LanguagePack Win32 app uploads the matching auto-generated
  wrapper from `Build\Output\LanguagePacks\DetectionScripts\` (not the
  generic `Detect-LanguagePack.ps1` from the source tree)
- [ ] Visio / Project apps have M365 Apps as a dependency with
  **Automatically install = Yes**
- [ ] ESP timeout bumped to ≥ 60 minutes
- [ ] Return code `17002` marked as **failed** in Win32 app config
- [ ] Assignments target the correct licensed Entra groups

See `docs/troubleshooting.md` if anything fails despite a green check in
Intune.
