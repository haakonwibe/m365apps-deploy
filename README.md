# 📦 m365apps-deploy

> A PowerShell-based deployment toolkit for **Microsoft 365 Apps for Enterprise**, **Visio**, **Project**, and language packs — purpose-built for **Microsoft Intune** Win32 app delivery on Windows Autopilot devices.

![Windows 10/11](https://img.shields.io/badge/Windows-10%20%2F%2011-0078D4?logo=windows&logoColor=white)
![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)
![Intune Win32](https://img.shields.io/badge/Intune-Win32-0078D4?logo=microsoft&logoColor=white)
![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)

---

## 🎯 Why this exists

The Intune deployment community has solved most of the hard parts of
shipping Office to Autopilot devices — detection, logging, language
packs, uninstall semantics — across a generous body of public scripts,
blog posts, and Microsoft Learn samples that this toolkit stands on.
What was missing for me was a single consolidated codebase that
covered all of it. This toolkit pulls those lessons together so your
team can own, fork, and audit **one** maintainable repo instead of
assembling and reconciling several for every new tenant.

| ❌ Failure mode                                                | ✅ This toolkit                                               |
|----------------------------------------------------------------|---------------------------------------------------------------|
| DisplayName-match detection false-positives on legacy MSI      | Reads `HKLM\...\ClickToRun\Configuration\ProductReleaseIds`   |
| `setup.exe` returns 0 but nothing installed                    | Post-install registry verification, exits **17002** on silent failure |
| Install fragments logs across `%TEMP%`, `ProgramFiles`, …      | One folder: `C:\ProgramData\M365AppsDeploy\Logs\`             |
| Raw text logs, no CMTrace support                              | Every line is CMTrace/OneTrace ready                          |
| `MatchInstalled` causing unsupported-language failures         | Per-product language matrix validated **before** `setup.exe`  |
| Visio uninstall nukes Office by accident                       | `<Remove All="FALSE">` with explicit product scoping          |

---

## 📑 Table of contents

- [✨ Features](#-features)
- [📐 Architecture at a glance](#-architecture-at-a-glance)
- [⚙️ Requirements](#️-requirements)
- [🔧 Two binaries you must supply](#-two-binaries-you-must-supply)
- [🗂️ Repository layout](#️-repository-layout)
- [🚀 Quickstart](#-quickstart)
- [⚙️ Optional build parameters](#️-optional-build-parameters)
- [🧩 Products & commands](#-products--commands)
- [📂 Log layout](#-log-layout)
- [📚 Documentation](#-documentation)
- [🧪 Tests](#-tests)
- [🙅 Out of scope](#-out-of-scope)
- [📄 License & versioning](#-license--versioning)

---

## ✨ Features

- 🧱 **Single-language baseline (`en-us`)** — one base image, per-group
  language overlays shipped as additional Win32 apps.
- 🪵 **CMTrace-compatible logs** — every script, session-header to
  footer, severity 1/2/3, PID, user context, and source-line trace.
- 🔁 **Rotation** at 10 MB; old log becomes `.log.old`.
- ✅ **Pre-flight checks** — elevation, pending reboot, disk space.
  Concurrency is delegated to ODT's own mutex (exit 1618 is surfaced
  accurately via `Get-ODTExitCodeResult`).
- 🔍 **Authoritative detection** — no DisplayName scans; reads the
  Click-to-Run `Configuration` hive directly.
- 🧪 **Catches ODT silent failures** — post-install registry verification
  turns "`setup.exe` returned 0 but nothing installed" into a loud
  `17002` exit.
- 🌍 **Language matrix validation** — rejects unsupported
  `(LanguageID, TargetProduct)` combos before ODT sees them.
- 🎁 **Add-on friendly** — Visio and Project install only on top of an
  existing Office install, with channel / architecture sanity checks.
- 🧰 **Evergreen OR bundled** `setup.exe`, your choice per deploy.
- 🏷️ **Per-product scoped uninstalls** — removing Visio leaves Office
  and Project untouched.
- 📦 **Ready-to-package** Build script wraps everything into
  `.intunewin` files, generates per-language detection wrappers, and
  emits a per-product `IntuneConfig.md` cheat-sheet for the Intune UI.
- 🏷️ **OCT-style optional tokens** — set `-CompanyName` (or persist it
  in `build-config.json`) and the value is substituted into staged
  XMLs at build time. Leave it unset and the corresponding line is
  removed from the XML — no `Your Company` placeholder ever leaks
  into a production install.
- 🌐 **Friendly channel names in logs** — registry CDN GUIDs are
  resolved to canonical ODT names (`MonthlyEnterprise`, `Current`,
  `PerpetualVL2021`, …) in every log line.
- 🧪 **Fast lab iteration** — same build script stages a
  copy-to-VM-ready tree at `Build\Staging\<Product>\` (use
  `-StagingOnly`), skipping the Intune upload-assign loop. See
  [`docs/local-testing.md`](docs/local-testing.md).
- ✔️ **Pester 5 unit tests** (94 tests) + an end-to-end lab harness.

---

## 📐 Architecture at a glance

```
                 ┌─────────────────────────────────────────┐
                 │       Microsoft Intune (Win32 apps)     │
                 └────────────────┬────────────────────────┘
                                  │ (install / uninstall / detect commands)
                                  ▼
        ┌─────────────┬─────────────┬─────────────┬───────────────┐
        │  M365Apps   │    Visio    │   Project   │ LanguagePacks │
        │ Install-*   │  Install-*  │  Install-*  │  Install-*    │
        │ Uninstall-* │ Uninstall-* │ Uninstall-* │  Uninstall-*  │
        │ Detect-*    │  Detect-*   │  Detect-*   │  Detect-*     │
        │ + base.xml  │ + base.xml  │ + base.xml  │ + template.xml│
        │ + Tools/    │ + Tools/    │ + Tools/    │ + Tools/      │
        └──────┬──────┴──────┬──────┴──────┬──────┴──────┬────────┘
               │             │             │             │
               └─────────────┴──────┬──────┴─────────────┘
                                    ▼
                         ┌──────────────────────────────┐
                         │           Common/            │
                         │  ODTLogging       (CMTrace)  │
                         │  ODTPrerequisites (pre-flight)│
                         │  ODTOfficeState   (detection) │
                         │  ODTInvoke        (install)   │
                         │  ODTLanguages     (matrix)    │
                         └──────────────┬───────────────┘
                                        ▼
                         ┌──────────────────────────────┐
                         │  setup.exe (ODT) /configure  │
                         └──────────────┬───────────────┘
                                        ▼
                ┌────────────────────────────────────────────────┐
                │  C:\ProgramData\M365AppsDeploy\Logs\           │
                │    • <Product>-Install.log                     │
                │    • <Product>-Uninstall.log                   │
                │    • <Product>-Detection.log                   │
                │  (ODT's native logs stay in %TEMP% - we don't  │
                │   redirect; see docs/troubleshooting.md.)      │
                └────────────────────────────────────────────────┘
```

Full details in [`docs/architecture.md`](docs/architecture.md).

---

## ⚙️ Requirements

| Requirement            | Version / notes                                          |
|------------------------|----------------------------------------------------------|
| 🖥️ Client OS           | Windows 10 / 11, 64-bit                                   |
| 🐚 PowerShell          | 5.1 (ships with Windows). 7+ also works                  |
| ☁️ Intune tenant       | Win32 app delivery enabled                                |
| 🪪 Enrolment           | Autopilot or direct MDM enrolment                         |
| 📦 ODT (`setup.exe`)   | Supplied per-product, or fetched at runtime              |
| 🛠️ `IntuneWinAppUtil`  | Required for building `.intunewin` packages              |

---

## 🔧 Two binaries you must supply

> ⚠️ Neither is committed to this repo. Both must be downloaded before
> building packages.

> 💡 **Easy way**: run `.\Source\Update-Tooling.ps1` — it downloads
> both binaries from Microsoft, **Authenticode-verifies the signatures**,
> and places them at their canonical locations (`Source\setup.exe` and
> `Build\IntuneWinAppUtil.exe`). It also writes a gitignored
> `Source\tooling-versions.json` manifest recording version + source URL
> + timestamp. The manual instructions below are the fallback for
> environments where scripted downloads aren't allowed.

### 1. `setup.exe` — Office Deployment Tool

- 🔗 <https://www.microsoft.com/en-us/download/details.aspx?id=49117>
- Extract `setup.exe` and drop it **once** into `Source\setup.exe`.
  `Build\Build-IntuneWinPackages.ps1` stages it into every product's
  `Tools\` folder at build time, so each `.intunewin` carries a copy.
- 🔀 **Per-product override**: want a specific ODT build for one
  product? Drop it into `<Product>\Tools\setup.exe` and run the build
  with `-SetupExeSource ''`.
- ✨ **Evergreen**: pass `-UseEvergreenSetup` to the install scripts to
  pull a fresh copy from Microsoft at run-time instead of bundling.

### 2. `IntuneWinAppUtil.exe` — Win32 Content Prep Tool

- 🔗 <https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool>
- Place at `Build\IntuneWinAppUtil.exe`, or pass
  `-IntuneWinAppUtilPath` to `Build\Build-IntuneWinPackages.ps1`.

---

## 🗂️ Repository layout

The repo has **three intentionally distinct layers** for each product.
Don't try to "deduplicate" — each layer serves a different purpose:

```
m365apps-deploy/
├── M365Apps/  Visio/  Project/  LanguagePacks/    <- Layer 1: AUTHORING
│   ├── Install-*.ps1                                 The only files you edit by hand.
│   ├── Uninstall-*.ps1                               Source of truth for the toolkit.
│   ├── Detect-*.ps1
│   └── Configurations/*.xml                          {{CompanyName}} placeholders here.
├── Common/                                          (shared across products at runtime)
│   └── ODT*.psm1
├── Source/                                          Shared inputs folder.
│   ├── Update-Tooling.ps1                           One-shot fetcher for the two
│   │                                                 Microsoft binaries (downloads,
│   │                                                 Authenticode-verifies, places).
│   ├── README.md                                    How to populate this folder.
│   └── setup.exe                                    (gitignored Microsoft binary)
├── Build/                                           Build pipeline (committed text outputs)
│   ├── Build-IntuneWinPackages.ps1
│   ├── Invoke-ProductStaging.ps1
│   ├── IntuneWinAppUtil.exe                         (gitignored Microsoft binary)
│   ├── Staging/<Product>/                          <- Layer 2: STAGING (post-substitution)
│   │   ├── (Layer-1 files copied + token-substituted)
│   │   ├── Configurations/                          {{CompanyName}} resolved or stripped.
│   │   ├── Tools/setup.exe                          (gitignored Microsoft binary)
│   │   └── Common/                                   Bit-for-bit what Intune extracts on
│   │                                                 a client - browsable on GitHub.
│   └── Output/<Product>/                           <- Layer 3: ADMIN-FACING ARTEFACTS
│       ├── *.intunewin                              (gitignored - encrypted binary blob)
│       ├── <Product>-IntuneConfig.md                Cheat-sheet for the Intune wizard.
│       └── DetectionScripts/                         Ready-to-upload detection scripts;
│                                                    one per simple product, one per
│                                                    language for LanguagePacks.
├── docs/                                            Architecture, intune-deployment,
│                                                    customization, troubleshooting,
│                                                    language-matrix, local-testing.
├── Tests/Pester/                                    94 unit tests (all mocked).
├── build-config.example.json                       Template for build-config.json
│                                                    (gitignored, holds your CompanyName).
└── CHANGELOG.md
```

**Why three layers?** Layer 1 is what you edit. Layer 2 captures
exactly what runs on the client — committed so reviewers can read
the deployed scripts on GitHub without cloning. Layer 3 is what an
admin uploads to Intune — the package, the cheat-sheet, the
detection script. Each layer is regenerated from Layer 1 by the
build pipeline; you should never edit Layers 2 or 3 directly.

The only excluded artefacts are Microsoft binaries (`setup.exe`,
`IntuneWinAppUtil.exe`) and the encrypted `.intunewin` blobs.
Everything else is committed text.

---

## 🚀 Quickstart

```powershell
# 1. Clone the repo.
git clone https://github.com/haakonwibe/m365apps-deploy
cd m365apps-deploy

# 2. Drop setup.exe into Source\ (one copy, shared), and drop
#    IntuneWinAppUtil.exe into Build\.

# 3. Build everything. Produces:
#      Build\Staging\<Product>\               <- staged tree (retained for lab testing,
#                                                committed to the repo for GitHub browsing)
#      Build\Output\<Product>\*.intunewin     <- Win32 package (binary, gitignored)
#      Build\Output\<Product>\DetectionScripts\ <- ready-to-upload detection scripts
#      Build\Output\<Product>\<Product>-IntuneConfig.md
#                                             <- cheat-sheet for the Intune UI
.\Build\Build-IntuneWinPackages.ps1

# Optional: bake an org name into this build's staged XMLs.
#   .\Build\Build-IntuneWinPackages.ps1 -CompanyName "Contoso Ltd"
# Or persist it in build-config.json (gitignored). See "Optional build
# parameters" below.

# 4. (Optional) run the Pester unit tests.
Invoke-Pester -Path .\Tests\Pester

# 5. Upload each .intunewin from Build\Output\<Product>\ to Intune.
#    Use the matching <Product>-IntuneConfig.md for the exact install /
#    uninstall / detection / dependency values to paste into the
#    Intune Win32 app wizard.

# Staging-only (for lab-VM iteration, no .intunewin produced):
#    .\Build\Build-IntuneWinPackages.ps1 -StagingOnly
# See docs\local-testing.md for the snapshot -> copy -> install -> revert flow.
```

---

## ⚙️ Optional build parameters

The build pipeline supports optional org-specific values that get
substituted into staged Configuration XMLs at build time. **Every value
is optional.** Building with no values set produces a fully generic
public-toolkit build with no organisation-specific data baked in — the
corresponding lines are simply removed from the staged XML, mirroring
how `config.office.com` (OCT) treats a blank field.

Resolution order:

1. CLI parameter (highest priority).
2. `build-config.json` at the repo root (gitignored). Copy
   `build-config.example.json` to `build-config.json` and fill in the
   values you want to persist across builds.
3. Unset (no substitution; line is removed during staging).

| Token          | Mode             | CLI parameter                              | What it controls                                                                                          | If unset / null                                                                                                 |
|----------------|------------------|--------------------------------------------|-----------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------|
| `CompanyName`  | scalar           | `-CompanyName "..."`                        | `<Setup Name="Company" Value="..."/>` in M365 Apps / Visio / Project base XMLs.                          | The `<Setup>` line is dropped, and the surrounding `<AppSettings>` block is stripped if it becomes empty.        |
| `ExcludedApps` | array (replace)  | `-ExcludedApps Access,Bing,Lync` (etc.)     | The default `<ExcludeApp>` set in `M365Apps/Configurations/m365apps-base.xml` (the `<Product>` block).   | The seven-app **modern default** is preserved as-is from the XML: `Access, Bing, Groove, Lync, OneDrive, Publisher, Teams`. |

```powershell
# Example 1: bake a company name into this build's staged XMLs.
.\Build\Build-IntuneWinPackages.ps1 -CompanyName "Contoso Ltd"

# Example 2: re-include Access (drop it from the exclusion list).
.\Build\Build-IntuneWinPackages.ps1 -ExcludedApps Bing,Groove,Lync,OneDrive,Publisher,Teams

# Example 3: install every Office app (no exclusions).
.\Build\Build-IntuneWinPackages.ps1 -ExcludedApps @()

# Or persist values in build-config.json (gitignored, never committed):
Copy-Item build-config.example.json build-config.json
# edit build-config.json
.\Build\Build-IntuneWinPackages.ps1
```

> ℹ️ `ExcludedApps` is an **array, replace-not-supplement**: an
> explicit value (even an empty array) overrides the entire default
> set. If you want the default plus one extra, list every entry you
> want. Unknown IDs fail the build with a clear error — ODT silently
> ignores them, which would otherwise ship a working-looking package
> that doesn't actually exclude what you asked for.

Adding a new token later is one line in the registration table at the
top of `Build\Invoke-ProductStaging.ps1` (`Get-DefaultBuildTokens`)
plus an optional CLI parameter on `Build-IntuneWinPackages.ps1`. The
substitution engine hard-fails on any `{{...}}` placeholder it finds
in source XMLs that is not registered, so typos surface at build time
rather than runtime.

---

## 🧩 Products & commands

Paste these into Intune's **Install command** and **Uninstall command**
fields. Detection is a custom script — use the files in the same folder.

| 🔹 Product     | ▶️ Install                                                                                              | ⏹️ Uninstall                                                                                              | 🔎 Detection                                          |
|----------------|---------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------|-------------------------------------------------------|
| **M365 Apps**  | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File Install-M365Apps.ps1`                           | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File Uninstall-M365Apps.ps1`                           | `Detect-M365Apps.ps1`                                 |
| **Visio**      | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File Install-Visio.ps1`                              | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File Uninstall-Visio.ps1`                              | `Detect-Visio.ps1`                                    |
| **Project**    | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File Install-Project.ps1`                            | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File Uninstall-Project.ps1`                            | `Detect-Project.ps1`                                  |
| **Language Pack** | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File Install-LanguagePack.ps1 -LanguageID nb-no` | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File Uninstall-LanguagePack.ps1 -LanguageID nb-no`     | upload `Build\Output\LanguagePacks\DetectionScripts\Detect-LanguagePack-nb-no.ps1` |

> 💡 Intune doesn't pass parameters to detection scripts. The build
> generates one self-contained wrapper per supported Office language
> at `Build\Output\LanguagePacks\DetectionScripts\Detect-LanguagePack-<LanguageID>.ps1`
> — upload the one that matches the language being deployed. See
> [`docs/intune-deployment.md`](docs/intune-deployment.md#detection-script-parameters--auto-generated-wrappers)
> for the pattern.

> ℹ️ **Standalone Proofing Tools is not supported.** Standalone
> `ProofingTools` installs are unreliable on current M365 Apps
> (the registry stub appears but Office's language UI doesn't
> recognise the proofing). Install the full Language Pack for the
> target language instead — Language Packs include proofing as
> part of the package.

### Dependencies at a glance

```
┌────────────────────────┐
│   Microsoft 365 Apps   │ ← base install (no dependencies)
└───┬────────┬────────┬──┘
    │        │        │
    ▼        ▼        ▼
 ┌─────┐ ┌────────┐ ┌─────────────────┐
 │Visio│ │Project │ │  Language Pack  │ (one per language)
 └─────┘ └────────┘ └─────────────────┘
```

In Intune, mark M365 Apps as a **dependency with Automatically install =
Yes** on every add-on app.

---

## 📂 Log layout

Everything the toolkit does lands in one place:

```
C:\ProgramData\M365AppsDeploy\Logs\
├── 📄 M365Apps-Install.log
├── 📄 M365Apps-Detection.log
├── 📄 M365Apps-Uninstall.log
├── 📄 Visio-Install.log
├── 📄 Visio-Detection.log
├── 📄 Project-Install.log
└── 📄 LanguagePack-O365ProPlusRetail-nb-no-Install.log

# ODT's native logs are NOT redirected — they live in %TEMP%.
# See docs/troubleshooting.md if you need them for deep debugging.
```

Every line is CMTrace-compatible:

```
<![LOG[Install succeeded.]LOG]!><time="16:47:30.315+120" date="04-24-2026"
    component="Install-M365Apps" context="SYSTEM" type="1" thread="23856"
    file="Install-M365Apps.ps1:145">
```

Open with:
- 🧰 [CMTrace.exe](https://learn.microsoft.com/mem/configmgr/core/support/cmtrace) (ships with ConfigMgr / MDT)
- 🧰 OneTrace
- 📝 Any plain-text editor (degrades gracefully)

> 🔒 If `C:\ProgramData\` is locked down in your org, override with
> `-LogPath` on every script — consistently across install, uninstall,
> and detection commands. See
> [`docs/customization.md`](docs/customization.md#6-log-path).

---

## 📚 Documentation

| 📘 Guide                                                          | What it covers                                          |
|-------------------------------------------------------------------|---------------------------------------------------------|
| [`docs/architecture.md`](docs/architecture.md)                    | Design decisions, module responsibilities, flow diagrams |
| [`docs/intune-deployment.md`](docs/intune-deployment.md)          | Step-by-step Intune Win32 upload procedure              |
| [`docs/local-testing.md`](docs/local-testing.md)                  | Iterate on a lab VM from `Build\Staging\` — no Intune loop |
| [`docs/customization.md`](docs/customization.md)                  | Adapting the toolkit to a new organisation              |
| [`docs/troubleshooting.md`](docs/troubleshooting.md)              | Known failure modes, exit codes, diagnostics            |
| [`docs/language-matrix.md`](docs/language-matrix.md)              | Per-product supported language codes                    |
| [`CHANGELOG.md`](CHANGELOG.md)                                    | Version history (SemVer)                                |

---

## 🧪 Tests

### Unit tests (safe on your dev box)

```powershell
Invoke-Pester -Path .\Tests\Pester
```

- ✅ 8 test files, **94 tests**, all mocked — no real registry or ODT
  calls.
- Covers: log line shape, rotation, path resolution, prerequisite
  wrappers, registry detection helpers, language-matrix validation,
  exit-code translation, channel GUID -> name resolution,
  build-time token substitution, per-language detection-script
  generation, staged-package integrity gate.

### End-to-end lab test (⚠️ actually installs Office!)

```powershell
# Disposable VM only. Installs + uninstalls real Office bits.
.\Tests\Invoke-DeploymentTest.ps1 -UseEvergreenSetup
```

Drives the full install → detect → uninstall lifecycle for every
product and prints a PASS/FAIL summary table.

---

## 🙅 Out of scope

This toolkit deliberately does **not** build:

- ❌ Entra dynamic group creation
- ❌ Intune app upload automation (use the portal or Graph API)
- ❌ License / service plan assignment
- ❌ Autopilot profile management
- ❌ Office activation troubleshooting
- ❌ End-user UI (all installs are silent by design)
- ❌ SCCM / ConfigMgr integration

Licensing of the Office bits is handled **externally** via Entra dynamic
groups that assign Win32 apps to the right users. That separation is
intentional — licensing logic is environment-specific and decouples
cleanly from install mechanics.

---

## 📄 License & versioning

- 📄 **License**: [MIT](LICENSE)
- 🔖 **Versioning**: [Semantic Versioning](https://semver.org/) — see
  [`CHANGELOG.md`](CHANGELOG.md).
- 🧷 **Current version**: `1.0.0`

---

<sub>Built for IT teams who'd rather own one maintainable toolkit than
re-stitch a deployment pipeline every Patch Tuesday.</sub>
