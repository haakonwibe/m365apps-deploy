# Architecture

This document captures the design decisions behind `m365apps-deploy`, and the
trade-offs we accepted. If you're tempted to change one of these, read the
rationale first so you can judge whether your environment's constraints
actually overlap with ours.

## Goals

1. **Consolidate the community's hard-won lessons** into one codebase an
   admin team can own, version, and modify.
2. **Deploy via Intune Win32 apps** to Windows Autopilot devices, with
   silent, reboot-tolerant installs that run under SYSTEM.
3. **Explain itself** via exhaustive CMTrace-readable logs — the single
   question "what happened on this machine?" should have one answer
   (`C:\ProgramData\M365AppsDeploy\Logs\`).
4. **Fail loudly, early, and with a clear reason**. Prerequisite checks
   and configuration mismatches are caught before setup.exe runs.
   Genuine silent ODT failures (setup.exe returns 0 but the product
   was not actually installed) are caught by a post-setup registry
   verify using the Registry64 helpers — see rule #3 in "Enforced
   architectural invariants" below.
5. **Stay portable**. No hardcoded tenant IDs, company names, license
   service plans, or region codes. Customisation is documented.

## Non-goals

Explicitly out of scope (see `README.md`):

- Entra dynamic group creation
- Intune app upload automation
- License / service plan assignment
- Autopilot profile management
- Office activation troubleshooting
- End-user UI
- SCCM / ConfigMgr integration

## Repository layout (committed build outputs)

The build pipeline's staging and output trees are **committed to the
repository** so the deployed-package layout is browsable on GitHub
without a clone-and-build. The only excluded artefacts are Microsoft
binaries (`setup.exe`, `IntuneWinAppUtil.exe`) and the encrypted
`.intunewin` blobs.

| Path                                        | Browsable on GitHub? | Notes                                                              |
|---------------------------------------------|----------------------|--------------------------------------------------------------------|
| `Build/Staging/<Product>/`                  | yes                  | Mirrors exactly what Intune extracts on a client. Read these to understand what runs at install / uninstall time. |
| `Build/Staging/<Product>/Tools/setup.exe`   | no                   | Microsoft binary - excluded from the repository.                   |
| `Build/Output/<Product>/<Product>-IntuneConfig.md` | yes           | Auto-generated cheat-sheet with the exact values to paste into the Intune Win32 app wizard. |
| `Build/Output/<Product>/DetectionScripts/`  | yes                  | Detection scripts ready to upload as the Intune custom detection script (one per simple product, one per language for LanguagePacks). |
| `Build/Output/<Product>/*.intunewin`        | no                   | Encrypted binary blob - excluded.                                  |

The committed staging tree is rebuilt from
`Build\Build-IntuneWinPackages.ps1` whenever the source scripts,
configuration XMLs, or `Common\` modules change. To inspect what a
client device actually receives without setting anything up locally,
read `Build/Staging/<Product>/` directly on GitHub - the file set
there is byte-identical to what `IntuneWinAppUtil.exe` packs into the
`.intunewin` (modulo the binaries listed above).

## Scope decisions

### Standalone Proofing Tools not supported

Standalone `Product ID="ProofingTools"` installs via ODT show
inconsistent behaviour on current M365 Apps (Monthly Enterprise
16.0.19929+): `setup.exe` returns 0 and the Uninstall registry
entry appears in Programs and Features, but Office's language UI
often does not register the proofing as installed. Multiple
template shapes have been tried (`Version="MatchInstalled"`,
explicit `OfficeClientEdition` + `Channel`, minimal, full); none
produce reliable results across test languages (sv-se, nn-no,
fr-fr). Rather than ship a feature that sometimes works, the
toolkit does not include a standalone Proofing Tools product.

**Alternative**: Users needing spell-check for a non-primary
language should install the full **Language Pack** for that
language. Language Pack installs include proofing as part of the
package and work reliably via the `Product ID="LanguagePack"`
pseudo-product. This is a slightly larger download (partial UI +
proofing) but one reliable path replaces two unreliable ones.

## Architectural decisions

### 1. Single-language base Office install

M365 Apps is deployed with `en-us` as the baseline. Administrators override
this by editing `M365Apps/Configurations/m365apps-base.xml` if they want a
different primary UI language. **Additional languages ship as separate
Win32 apps** via the `LanguagePacks/` workflow.

Why: `en-us` is universally supported across every Click-to-Run
product (Office, Visio, Project). Using it as the baseline means one
base image for the entire organisation, with per-user-group language
overlays on top. This matches how Microsoft's own guidance handles
multi-lingual orgs.

### 2. Visio and Project as add-on installs

Channel and architecture **must match** the existing Office install. The
install scripts warn on channel drift and hard-fail on architecture
mismatch before even launching `setup.exe`, because those mismatches
produce cryptic ODT errors.

We do **not** use `Language ID="MatchInstalled"` for Visio/Project add-ons.
The Office language matrix and the Visio/Project matrix are **not
identical** — `MatchInstalled` can resolve to a language Visio does not
support, and ODT fails silently. Instead, we read the existing C2R
`Configuration` key, pick an explicit matching language, and validate it
against `Common/ODTLanguages.psm1` before running.

### 3. License-based assignment handled externally

The toolkit doesn't know which users get Visio. Administrators assign Win32
apps to Entra dynamic groups keyed on service plan. This is out of scope
for the toolkit — and intentionally so, because licensing logic is
environment-specific and decouples cleanly from the install mechanics.

### 4. Consolidated logging location

Every toolkit-produced log lands under
`C:\ProgramData\M365AppsDeploy\Logs\`:

| File                                                   | Written by                              |
|--------------------------------------------------------|------------------------------------------|
| `M365Apps-Install.log` / `-Uninstall.log` / `-Detection.log` | `M365Apps\*.ps1` scripts          |
| `Visio-*.log`                                          | `Visio\*.ps1`                            |
| `Project-*.log`                                        | `Project\*.ps1`                          |
| `LanguagePack-<Product>-<lang>-Install.log` etc.       | `LanguagePacks\*.ps1`                    |

These wrapper logs are the **primary troubleshooting source** - they
carry the CMTrace-formatted record of every step the scripts take, the
prerequisite-check results, the setup.exe exit code (translated), and
any silent-failure detection.

#### ODT native logs — deliberately NOT redirected

ODT supports a `<Logging Level="Standard" Path="..." />` element in the
configuration XML to redirect its native logs. The toolkit does **not**
inject this element. Reasons:

1. The element is unreliable on modern ODT builds — in practice logs
   often still land in `%TEMP%` regardless of what `Path` is set to.
2. The native output is verbose enough that it drowns the
   troubleshooting-signal ratio below what the wrapper logs already
   provide.

So: our wrapper logs under `C:\ProgramData\M365AppsDeploy\Logs\` are
the authoritative record. If you do need raw ODT native logs for deep
setup.exe debugging, look in `%TEMP%` on the client — ODT writes files
matching `%TEMP%\<ComputerName><timestamp>.log` by default. See
`docs/troubleshooting.md`.

### 5. CMTrace-compatible log format

Admins troubleshooting failed Autopilot flows already use CMTrace or
OneTrace from their SCCM / MDT work. Matching that format means zero
onboarding cost for support staff. Plain-text tools still work on the same
files.

### 6. Bundled `setup.exe` by default, evergreen optional

Bundling a known-good `setup.exe` inside each `.intunewin` gives
reproducibility: the same installer ran on every device in the rollout,
regardless of whether Microsoft happened to ship an ODT update that week.

Evergreen download (`-UseEvergreenSetup`) is provided for environments that
prefer always-latest ODT behaviour. Retries with exponential backoff
(3 attempts) guard against transient CDN failures.

The toolkit ships a third option for refreshing the bundled binary:
**`Source\Update-Tooling.ps1`** is an admin-invoked helper that
downloads `setup.exe` (from the same evergreen URL) plus
`IntuneWinAppUtil.exe` (from the GitHub release), Authenticode-verifies
both, drops them at their canonical locations
(`Source\setup.exe`, `Build\IntuneWinAppUtil.exe`), and records
version metadata in a gitignored manifest at
`Source\tooling-versions.json`. The script is the recommended way
to refresh the toolchain on a fresh clone or on a fork that wants
to bump to the latest ODT before a release. The build pipeline
itself remains **network-free** - Update-Tooling is a separate,
explicit operation; the build expects pre-existing files at
canonical locations and never reaches out to the network.

### 7. Configuration XMLs bundled, external URL optional

Same rationale as `setup.exe`: reproducibility by default, overridable at
deploy time with `-ConfigurationURL` for teams that want central config
management (e.g. blob storage).

## Module responsibilities

```
Common/
├── ODTLogging.psm1        # CMTrace lines, session headers/footers, rotation
├── ODTPrerequisites.psm1  # Elevation / pending-reboot / disk-space checks
├── ODTOfficeState.psm1    # Read C2R registry, authoritative detection helpers
├── ODTInvoke.psm1         # XML injection, setup.exe resolution, process launch
└── ODTLanguages.psm1      # Per-product language matrix + validation
```

### Note on `ODTInvoke.psm1` and `ODTLanguages.psm1`

The original specification listed only three Common modules: `ODTLogging`,
`ODTPrerequisites`, `ODTOfficeState`. We added two more:

- **`ODTInvoke.psm1`** captures the shared install flow primitives used by
  every `Install-*.ps1` and `Uninstall-*.ps1` script. Without it, the same
  XML-injection / setup-resolution / exit-code translation code would be
  copied five times across Install scripts plus five times across
  Uninstall scripts. The primitives are trivial to inline into individual
  scripts if you disagree — the module is a DRY convenience, not an
  architectural commitment.

- **`ODTLanguages.psm1`** holds the per-product language matrix used
  by the LanguagePack workflow. The matrix appears in exactly one
  place, and `docs/language-matrix.md` is the human-readable mirror.
  Without it, the install script would need its own copy — increasing
  drift risk as Microsoft updates language availability.

Both are exported and callable from outside the toolkit if you want to
reuse them for adjacent scripts (e.g. a pre-flight audit job).

## Intune execution environment

The Intune Management Extension (IME) is the agent on the client that
executes Win32 app install / uninstall commands and detection scripts.
A handful of IME facts shape how the toolkit's scripts run, and the
"Enforced architectural invariants" section below directly addresses
the consequences.

### IME is a 32-bit binary

`IntuneManagementExtension.exe` lives at
`C:\Program Files (x86)\Microsoft Intune Management Extension\`. When
it spawns child processes (`powershell.exe`, `cmd.exe`), Windows file
system redirection picks up the SysWOW64 copy — i.e. the **32-bit**
PowerShell. Inside that 32-bit process, every `HKLM:\SOFTWARE\...`
access is silently redirected to `HKLM:\SOFTWARE\WOW6432Node\...`.

This is why the toolkit reads the registry through the explicit
`Registry64` view (rule #3 below) — keys like
`HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration` only
exist in the 64-bit view, regardless of whether the installed Office
is 32-bit or 64-bit.

### Detection scripts have their own bitness toggle

The Win32 app's "Custom detection script" UI exposes a "Run as 32-bit
process on 64-bit clients" toggle, separate from the install command.
The auto-generated cheat-sheet
(`Build\Output\<Product>\<Product>-IntuneConfig.md`) sets it to
**No**, so detection runs in 64-bit context — but the toolkit's
detection scripts use the explicit `Registry64` view anyway, so they
work either way.

### Where things land at runtime

| Path                                                              | What                                                                    |
|-------------------------------------------------------------------|-------------------------------------------------------------------------|
| `C:\Windows\IMECache\<app-guid>_<version>\`                       | Where IME extracts the `.intunewin` payload before running install      |
| `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\`        | IME's own logs (captures install command stdout/stderr, exit codes)     |
| `C:\ProgramData\M365AppsDeploy\Logs\`                             | Toolkit logs (CMTrace-formatted, independent of IMECache lifecycle)     |

IME sets the IMECache folder as the working directory before running
the install command. The toolkit's install scripts use `$PSScriptRoot`
(in the script body, not in param defaults — see rule #2 below) to
locate `Tools\setup.exe`, `Configurations\*.xml`, and `Common\*.psm1`
relative to themselves. The detection script is uploaded to Intune
separately (not packaged inside the `.intunewin`); IME drops it in a
temp location at run time.

### Detection retry cadence

After the install command exits, IME runs the configured detection
script. If detection returns non-zero (not detected), IME re-runs
detection on its own retry schedule — typically tens of seconds —
without re-running the install. This is why "Installed" can show up
in Company Portal a short while after the install command exits:
detection catches up once the Click-to-Run service finishes its
registry registration.

The toolkit's install scripts also verify the install via
`Test-ProductInstalled` immediately after `setup.exe` returns
(step 8 of the install flow). Both that in-script verify and
Intune's separate detection run see the same registry — they're
consistent because both use the `Registry64` view.

### Exit code interpretation

IME captures the install command's exit code and matches it against
the Win32 app's "Return codes" table. The toolkit uses ODT-standard
codes — `0`, `3010`, `1641` = success; `1618` = retry; `1603` = failed;
`17002` = ODT-reported failure (including the silent-failure
post-check). Mapping `17002` to **Failed** in the Win32 app config
is required: without it, IME treats a toolkit silent-failure exit as
success, the failing detection verdict surfaces alone, and the
install-side error stays hidden from operator reports.

## Enforced architectural invariants

Three architectural rules ensure the toolkit works correctly under the
Intune execution environment described above. Each is enforced by a
Pester test.

### 1. Detection scripts are standalone

Intune's Win32 detection-script model runs detection scripts in a sandbox
that does not reliably see the product folder siblings (`Common/`), so
`Import-Module` from a relative path is fragile. Two solutions exist:

1. Copy critical helpers **inline** into each detection script.
2. Deploy `Common/` separately via Intune Device Configuration and have
   detection scripts bootstrap from a fixed path.

We chose **option 1**. The duplicated code is small and the portability
win is significant — no out-of-band Device Config is required. The
detection scripts are self-contained and can be reused on non-Intune
platforms as drop-in health checks.

What gets duplicated today:

- A small **CMTrace-line writer** so the detection script can produce
  the same log shape as the install/uninstall scripts.
- The **registry lookup for `ProductReleaseIds`** in
  `Detect-M365Apps.ps1`, plus its `<TargetProduct> - <lang>` Uninstall
  hive scan in `Detect-LanguagePack.ps1`.
- A 7-row **GUID -> friendly channel-name table** in
  `Detect-M365Apps.ps1` so `Channel=...` log lines
  print `MonthlyEnterprise` instead of the raw CDN URL. The canonical
  table lives in `Common\ODTOfficeState.psm1`
  (`Get-OfficeChannelName`) — both copies have a "keep in sync"
  comment pointing at this section.

For LanguagePacks, the build pipeline goes one step further: it
generates one self-contained per-language detection wrapper at
`Build\Output\LanguagePacks\DetectionScripts\Detect-LanguagePack-<lang>.ps1`
by reading the canonical `LanguagePacks\Detect-LanguagePack.ps1`,
slicing off its param block, and prepending hard-coded `LanguageID` /
`TargetProduct` values. The body is verbatim from the source, so the
detection logic stays in one place even though there are ~110 wrappers
on disk.

**Enforced by**: `Tests\Pester\DetectionScriptsStandalone.Tests.ps1` —
AST inspection asserts no `Import-Module` calls in any `Detect-*.ps1`
script in the four product folders.

### 2. Param defaults must not reference $PSScriptRoot

PowerShell evaluates param-block default expressions BEFORE
`$PSScriptRoot` is reliably populated when scripts are launched via
`powershell.exe -File <script>` under non-interactive hosts (Intune
Management Extension, PsExec -s). A default like
`[string] $SetupExePath = (Join-Path -Path $PSScriptRoot -ChildPath ...)`
binds to `''` in those contexts; the script then exits 1 with no
log because `Join-Path` throws "Cannot bind argument to parameter
'Path'" before `Start-ODTLogSession` runs.

The canonical pattern is to declare the param without a default and
resolve in the script body where `$PSScriptRoot` is reliable:

```powershell
param( [string] $SetupExePath )
if ([string]::IsNullOrEmpty($SetupExePath)) {
    $SetupExePath = Join-Path -Path $PSScriptRoot -ChildPath 'Tools\setup.exe'
}
```

**Enforced by**: `Tests\Pester\ParamBlockHygiene.Tests.ps1` — AST
inspection of every Install/Uninstall script's param block.

### 3. Registry reads must use the explicit 64-bit view

See "Intune execution environment" above for why install commands
launch in 32-bit PowerShell on 64-bit Windows and why default
`HKLM:\SOFTWARE\...` access then misses the keys we care about.

The toolkit reads the registry through `Microsoft.Win32.RegistryKey`
with the `Registry64` view explicitly. Three private helpers in
`Common\`:

- `Get-Registry64Item -Path 'SOFTWARE\...'` — values as a PSCustomObject
- `Get-Registry64SubKeyName -Path 'SOFTWARE\...'` — array of subkey names
- `Test-Registry64KeyExists -Path 'SOFTWARE\...'` — bool

Detection scripts (rule #1: standalone) inline the equivalent
`[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)`
call directly.

Note the path argument has **no `HKLM:\` prefix** — the hive comes from
the `OpenBaseKey` enum, the path is relative to that hive root. The
`Registry64` view sees `WOW6432Node` as a literal sub-key under
`SOFTWARE`, so 32-bit Uninstall hive entries are still reachable via
`'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'`.

**Consumers**: `Get-OfficeConfiguration`, `Test-ProductInstalled`,
`Test-LanguagePackInstalled`, and `Get-InstalledLanguages` (in
`ODTOfficeState.psm1`) plus `Test-PendingReboot` (in
`ODTPrerequisites.psm1`) all go through these helpers. The install
and uninstall scripts call them both for pre-flight checks
(channel / architecture reconciliation, "is base Office installed?",
no-op short-circuits) and for the post-setup silent-failure verify
(catches the case where `setup.exe` returns 0 but the product was
not actually installed or removed).

**Bitness-of-Office independence**: the C2R service
(`OfficeClickToRun.exe`) is uniformly 64-bit on 64-bit Windows and
writes its Configuration key to the 64-bit view regardless of whether
it is managing 32-bit or 64-bit Office. The installed Office bitness
is recorded *inside* that 64-bit-located key as `Platform = x64` or
`Platform = x86`. The Registry64 helpers therefore work for both
`OfficeClientEdition="64"` and `OfficeClientEdition="32"`
deployments without code changes.

**Enforced by**: `Tests\Pester\RegistryAccessHygiene.Tests.ps1` — AST
inspection scans every `.ps1` / `.psm1` in `M365Apps\`, `Visio\`,
`Project\`, `LanguagePacks\`, `Common\` and fails if it finds
`Test-Path` / `Get-ItemProperty` / `Get-ChildItem` (and similar)
called with a literal `HK<HIVE>:\` argument.

## Build-time tokens vs runtime values

Two kinds of `{{...}}` placeholder live in the source XMLs and they
must not be confused:

| Kind | Where resolved | Examples | If unset |
|------|----------------|----------|----------|
| **BuildTime** (token) | `Build\Build-IntuneWinPackages.ps1` calls `Invoke-XmlTokenSubstitution` during staging. | `{{CompanyName}}` | The whole **line** containing the placeholder is removed from the staged XML. Surrounding `<AppSettings>` block is stripped if it becomes empty. Mirrors how `config.office.com` (OCT) treats blank fields. |
| **Runtime** (pass-through) | `Install-LanguagePack.ps1` substitutes against live device state at install time. | `{{OfficeClientEdition}}`, `{{Channel}}`, `{{LanguageID}}` | N/A — these always resolve to a real value at install time; build-time engine leaves them intact. |

These are **tokens** by toolkit convention. They sit on top of values
that ODT itself requires to be exactly correct — `Channel`,
`OfficeClientEdition`, `Product ID`, `Language ID` in the `<Add>` /
`<Product>` / `<Language>` elements. Those are **not tokens**: a wrong
value isn't "blank" or "unset", it's a hard ODT failure. Don't try to
make them optional via this mechanism.

Adding a new BuildTime token is one line in
`Get-DefaultBuildTokens` (`Build\Invoke-ProductStaging.ps1`) plus an
optional CLI parameter on `Build-IntuneWinPackages.ps1`. The
substitution engine hard-fails on any `{{...}}` placeholder that
isn't in the registration table, so typos surface at build time
rather than runtime.

### The default `ExcludedApps` set is an architectural decision

`ExcludedApps` is an `ArrayExpansion`-mode token, but the default
list it ships with is not a customization knob — it is a stance the
toolkit takes about which Office apps belong on a 2026-era managed
device. The seven-app default is:

`Access, Bing, Groove, Lync, OneDrive, Publisher, Teams`

Rationale per app:

- **Access** — Windows-only with no Mac parity, with a small,
  concentrated user base that's almost always identifiable. Modern
  organisations route those workloads to SharePoint Lists / Power
  Apps / Dataverse. Shipping Access on every endpoint as the
  default makes it harder to find the workloads that genuinely
  depend on it.
- **Publisher** — on Microsoft's documented retirement track and
  excluded from new SKUs. Shipping a known-dead client is the
  wrong default.
- **Bing, Groove, Lync** — legacy / extension components most orgs
  have always excluded.
- **OneDrive, Teams** — deployed via their own bootstrappers in
  modern tenants, not via ODT. Letting Office add a parallel
  install path produces version-skew confusion at first launch.

OneNote stays in. The UWP retirement made the desktop OneNote the
default again, so it belongs alongside Word / Excel / PowerPoint /
Outlook in a normal install.

Forks that disagree should override `ExcludedApps` via
`build-config.json` rather than editing the source XML — that keeps
the fork from drifting against upstream.

Two engine guardrails make this safe:

1. **ID validation against the canonical Microsoft set.** The
   token's `KnownValues` list is the union of the
   [official ODT `ExcludeApp` ID list](https://learn.microsoft.com/microsoft-365-apps/deploy/office-deployment-tool-configuration-options#excludeapp-element)
   plus `Bing`. A typo (`Acess`) fails the build before staging
   starts. ODT silently ignores invalid IDs at install time, so a
   typo would otherwise ship a working-looking package that
   installs Access on every endpoint.
2. **Deterministic output.** The engine sorts the resolved array
   case-insensitively before emission. Two builds from the same
   config produce byte-identical staged XML. Important for the
   committed-Staging / committed-Output story — a docs-only PR
   shouldn't churn the staged XML just because someone listed
   the array elements in a different order.

## Three-layer build flow

The pipeline produces three intentionally distinct layers per product.
Each layer is generated from the previous one and is read by a
different audience.

```
Layer 1 — AUTHORING (root)              Edit by hand. Source of truth.
┌───────────────────────────────────┐
│ M365Apps/                         │
│   Install-M365Apps.ps1            │
│   Uninstall-M365Apps.ps1          │
│   Detect-M365Apps.ps1             │
│   Configurations/m365apps-base.xml│   {{CompanyName}} placeholder
│ Visio/  Project/  LanguagePacks/  │   (and similar)
│ Common/ODT*.psm1                  │
└────────────────┬──────────────────┘
                 │ Build-IntuneWinPackages.ps1
                 │   Phase 1: Invoke-ProductStaging
                 │     - Copy Layer 1 -> Layer 2
                 │     - Apply Invoke-XmlTokenSubstitution
                 │       (BuildTime tokens substitute or strip-line;
                 │        Runtime tokens left intact)
                 │     - Stage Common/ + Tools/setup.exe
                 │     - Test-StagedPowerShellFiles integrity gate
                 ▼
Layer 2 — STAGING (committed text)      Bit-for-bit what Intune extracts on
┌───────────────────────────────────┐   a client. Read this on GitHub to see
│ Build/Staging/<Product>/          │   what actually runs at install time.
│   <Layer 1 scripts copied>        │
│   Configurations/                 │   Substitution applied:
│     <e.g. <Setup Name="Company"   │     - if -CompanyName "Acme" was passed,
│           Value="Acme"/>>         │       Company line carries Acme
│                                   │     - if not, the line is gone, and
│                                   │       <AppSettings> is stripped if
│                                   │       it ended up empty
│   Tools/setup.exe                 │   (gitignored binary)
│   Common/*.psm1                   │
└────────────────┬──────────────────┘
                 │   Phase 2: IntuneWinAppUtil.exe
                 │     - Wrap Build\Staging\<Product>\ into .intunewin
                 │   Phase 3: Publish-DetectionScripts
                 │     - Copy / generate detection scripts to
                 │       Build\Output\<Product>\DetectionScripts\
                 │   Phase 4: Write-IntuneConfigDoc
                 │     - Emit <Product>-IntuneConfig.md cheat-sheet
                 ▼
Layer 3 — ADMIN ARTEFACTS               What an admin uploads to Intune.
┌───────────────────────────────────┐
│ Build/Output/<Product>/           │
│   *.intunewin                     │   (gitignored encrypted blob)
│   <Product>-IntuneConfig.md       │   Auto-generated cheat-sheet
│   DetectionScripts/               │
│     Detect-<Product>.ps1          │   For simple products
│     Detect-LanguagePack-<lang>.ps1│   For LanguagePacks (~110 wrappers)
└───────────────────────────────────┘
```

**Why all three are committed (except the binaries)**: the project's
public-fork model means a reviewer should be able to read on GitHub
both *the code we author* (Layer 1) and *the bytes a managed device
actually receives* (Layer 2), with no clone-and-build step.
Layer 3's text artefacts (`IntuneConfig.md`, detection scripts) are
the same bytes admins paste / upload to the Intune UI, so committing
them means a fork's release notes can link directly to the upload
artefacts.

The `.intunewin` and `setup.exe` files in Layers 2/3 are binaries
and stay gitignored. Everything else is committed text.

## Install-flow sequence

For every `Install-*.ps1`:

```
1. Import Common/ modules
2. Start-ODTLogSession
3. Invoke-ODTPrerequisiteChecks  (Elevation, PendingReboot, DiskSpace -
                                   see "Concurrency is delegated to ODT"
                                   below; there is no NoRunningSetup check)
4. Product-specific validation
   - M365 Apps: none (no dependency)
   - Visio/Project: require O365ProPlusRetail installed + matching channel/arch
   - LanguagePack: require -TargetProduct installed + language in matrix
5. Resolve-ODTConfigurationPath  (local | URL | bundled default)
6. Resolve-ODTSetupPath          (bundled | evergreen download)
7. Invoke-ODTSetup               (setup.exe /configure, capture exit code)
8. Post-install verification     (Test-ProductInstalled — registry check
                                  via Registry64 helpers, catches silent
                                  ODT failures)
9. Stop-ODTLogSession
10. exit <code>
```

Any failure between steps 3 and 9 is caught, logged with severity 3, and
turned into an appropriate non-zero exit code. Intune reads the exit code
to decide whether to retry. The post-install verify (step 8) goes through
`Test-ProductInstalled` → `Get-Registry64Item`, so it correctly reads the
C2R Configuration key regardless of which bitness IME launches the script
in — see rule #3 in "Enforced architectural invariants".

### Concurrency is delegated to ODT (no pre-flight check)

`Invoke-ODTPrerequisiteChecks` deliberately does **not** scan for other
setup.exe / Click-to-Run processes before launching the install. ODT
and the underlying Windows Installer already use a global mutex to
serialise concurrent operations — if another install is truly in
flight, setup.exe returns `1618` ("Another installation is already in
progress") or a related code (0-1018, 17003-2031, 2035-0, etc.), and
the wrapper's `Get-ODTExitCodeResult` translates that directly into a
`Failed (another install in progress)` result line. Intune sees the
non-zero exit and retries on its own schedule.

The toolkit deliberately does **not** include a `Test-NoRunningSetup`
check that scans for `setup.exe` / `OfficeClickToRun.exe` in the
process list. Reasons:

- `OfficeClickToRun.exe` is the always-running C2R background service,
  not an install in flight — false-positive on every device where
  M365 Apps is already deployed, which is precisely the target of
  every Visio / Project / language-pack install.
- Even a tightened check (scenarios-registry probe, etc.) adds no
  value over ODT's own mutex.
- The post-hoc exit-code path is Microsoft's documented way of
  handling concurrency: [Microsoft 365 Apps deployment exit codes](https://learn.microsoft.com/microsoft-365-apps/deploy/overview-deploying-languages-microsoft-365-apps).

Principle: don't replicate checks that the underlying tool already
does better. Trust ODT's concurrency handling.

## Uninstall-flow sequence

Same as install but with:

- Step 4 replaced with a "is the product actually installed?" check —
  uninstall is a no-op if not.
- Step 8 verifies the **absence** of the product instead of presence.
- The removal XML uses `<Remove All="FALSE">` with an explicit `<Product>`
  element so **only the targeted product** is removed. Running
  `Uninstall-Visio.ps1` never touches Office or Project.
- `Uninstall-M365Apps.ps1` is surgical by default (see "Uninstall
  semantics" below) — removes only `O365ProPlusRetail` and
  `LanguagePack`. Pass `-RemoveAll` to trigger the nuclear
  `<Remove All="TRUE" />` path.

## Uninstall semantics

Microsoft 365 Apps, Visio, and Project are **all Click-to-Run products
sharing the same on-device C2R engine and configuration hive**. A naive
"uninstall Office" operation via ODT's `<Remove All="TRUE" />` tears
the whole C2R stack down — Office, Visio, Project, every language
pack, and the C2R engine itself. That would surprise an admin running
`Uninstall-M365Apps.ps1` on a device with Visio when they found Visio
gone too.

The toolkit separates the two semantics explicitly:

### Surgical (default, no `-RemoveAll`)

`Uninstall-M365Apps.ps1` uses `M365Apps/Configurations/m365apps-remove.xml`:

```xml
<Remove>
  <Product ID="O365ProPlusRetail" />
  <Product ID="LanguagePack" />
</Remove>
```

- **`<Language>` omitted intentionally.** Per Microsoft's ODT docs:
  "To remove all the installed languages, don't include the language
  attribute." ODT auto-discovers and removes every language the
  product registered.
- **`LanguagePack` pseudo-product included as a second `<Product>`** so
  accessory language packs installed via `Install-LanguagePack.ps1`
  (which registers them under `LanguagePack - <lang>`) are cleaned
  up alongside Office. Without this line, those would orphan.
- Visio (`VisioProRetail`), Project (`ProjectProRetail`), and language
  additions that were attached directly to those products (e.g.
  `VisioProRetail - nb-no`) are left untouched.

### Nuclear (`-RemoveAll`)

`Uninstall-M365Apps.ps1 -RemoveAll` uses
`M365Apps/Configurations/m365apps-removeall.xml`:

```xml
<Remove All="TRUE" />
```

- Removes every Click-to-Run product on the device.
- Removes the C2R engine itself.
- Reserved for lab rebuilds, full migrations, and the rare case of
  decommissioning all Microsoft 365 Apps products together.

### C2R engine lifecycle after surgical removal

If you surgically remove the **last** remaining C2R product (for
example, only Office was installed and you uninstall it), the C2R
engine is **not** guaranteed to clean itself up. You may see the
`HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration` key
lingering with `ProductReleaseIds` empty.

A follow-up `Uninstall-M365Apps.ps1 -RemoveAll` finishes the
teardown. We do not auto-chain from surgical → nuclear because doing
so would defeat the explicit-intent design that motivated the
surgical default in the first place.

### Intune deployment implication

For the Intune Win32 app representing Microsoft 365 Apps for
Enterprise, configure the uninstall command as the **surgical
default**:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File Uninstall-M365Apps.ps1

Admins who want a full C2R wipe should do it manually (adding
`-RemoveAll` when they run the script) or via a separate Intune app
whose uninstall command includes the switch. The default app should
not silently tear down Visio and Project when an admin unassigns
Office.

## Exit code policy

| Code   | Meaning                                                          | Intune behaviour            |
|--------|------------------------------------------------------------------|-----------------------------|
| 0      | Success                                                          | Mark as installed           |
| 3010   | Success; reboot required                                         | Mark as installed + reboot  |
| 1641   | Success; reboot initiated                                        | Mark as installed           |
| 1618   | Another install in progress — retryable                          | Retry                       |
| 1603   | Fatal install failure (generic) — we map unexpected errors here  | Mark as failed              |
| 17002  | ODT reported a failure, including silent-failure post-checks     | Mark as failed              |
| others | Forwarded from ODT as-is                                         | Interpreted by Intune       |

## Running the tests

- `Tests/Pester/` — unit tests for every `Common/` module. Run locally
  with `Invoke-Pester -Path .\Tests\Pester`. Safe to run on your dev box:
  all registry and process lookups are mocked.
- `Tests/Invoke-DeploymentTest.ps1` — end-to-end lab harness that actually
  installs real Office bits. **Only run on a disposable VM**. Produces a
  PASS/FAIL summary table.

## Open questions / deliberate fuzzy edges

- **`en-gb` Visio install**. Documented as supported but has a history of
  failing with "Language not available" on certain Visio builds.
  `ODTLanguages.psm1` currently accepts it for Visio; if your lab test
  fails, drop it from the `$script:VisioLanguages` array for the affected
  build. See `docs/troubleshooting.md`.
- **Pinned shortcuts**. If you run `RemoveMSI` on Windows 7 SP1, user-pinned
  shortcuts from the old Office can linger. This is a known ODT quirk and
  won't affect Windows 10/11 deployments, which is our target.
