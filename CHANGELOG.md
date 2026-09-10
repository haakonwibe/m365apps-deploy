# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.9] - 2026-09-10

### Added

- **In-flight install progress logging.** `Invoke-ODTSetup` samples the machine
  every `-ProgressIntervalSeconds` (default 30) while `setup.exe` is running and
  writes one CMTrace line per sample, so a long install is a readable timeline
  rather than a single duration. Each line reports the live Click-to-Run
  scenario task (`STREAM`, `APPLYCONFIGURATION`, `INTEGRATE_INSTALL`, ...),
  network throughput, system-drive free space and its delta, and CPU / working
  set / IO for `setup.exe` and the Click-to-Run processes. Sampling waits on the
  process itself, so it adds no time to the install, and the lines survive a run
  cut short by an ESP timeout. Samples reach the caller through an optional
  `-ProgressCallback` scriptblock, keeping `Common/ODTInvoke.psm1` free of any
  cross-module dependency.

- **`Get-ODTC2RPhaseTimeline`** (`Common/ODTInvoke.psm1`) reads the
  `HKLM\SOFTWARE\Microsoft\Office\ClickToRun\UpdateStatus` timestamps and
  returns Detection / ClientDownload / Download / Apply / Finalize spans - the
  download-vs-apply split Click-to-Run publishes for itself. Registry only: no
  log files are read, copied or redirected, and the toolkit's position on ODT's
  native `<Logging>` element is unchanged.

- **`Get-ODTSessionElapsed` and `Write-ODTPhase`** (`Common/ODTLogging.psm1`)
  emit `PHASE [t+HH:MM:SS] <Name>` markers measured from the session start
  already tracked by `Start-ODTLogSession`, so the cost of each stage of a run
  is readable directly from the log.

- **`Install-M365Apps.ps1` records when the Intune Management Extension staged
  the payload** (`Payload staged at ...`), which quantifies part of the window
  that precedes the install script.

- **`-RemovePreinstalledConsumerOffice`** on `Install-M365Apps.ps1`, with the
  new `M365Apps/Configurations/m365apps-remove-consumer.xml`. Removes a
  consumer Click-to-Run Office shipped on a vendor image in its own ODT pass
  before the enterprise install. `<RemoveMSI />` covers Windows Installer
  products only, so without this the consumer SKU stays registered alongside
  `O365ProPlusRetail`. Off by default; a failed removal never blocks the
  install.

- **`-ProgressIntervalSeconds`** on `Install-M365Apps.ps1` to tune or disable
  progress logging per deployment.

- **`docs/examples/` - ready-to-copy `build-config.json` files** for four common
  rollout shapes: `en-us`, `en-gb`, a multi-country European rollout, and
  Norwegian Bokmal + Nynorsk. The multi-language examples show the supported
  pattern - one base UI language, additional languages as separate Win32 apps
  from `LanguagePacks/`. Guarded by
  `Tests/Pester/BuildConfigExamples.Tests.ps1`, which checks each example is
  valid JSON, uses a scalar language present in the matrix, and references only
  language packs that can be built.

- **Section 7 of the generated `<Product>-IntuneConfig.md`** now states the
  language baked into the package, read back from the staged configuration, so
  the resolved value is visible at upload time.

### Changed

- **`Invoke-ODTSetup` result object gained fields** - `TimedOut`, `StartedUtc`,
  `EndedUtc`, `SampleCount`, `Samples`, `PhaseSummary` and `DisabledSamplers`.
  `ExitCode`, `DurationSeconds`, `Success` and `Message` are unchanged in name,
  type and meaning, so every existing caller is unaffected.

- **`Invoke-ODTSetup -TimeoutMinutes` range widened from 5-240 to 1-240**, so
  the timeout path can be exercised in a lab without a five-minute wait. The
  default is still 60 minutes and the timeout result is unchanged
  (`ExitCode = -1`, same message text).

- **Progress and phase lines use invariant number formatting**, so logs read
  identically regardless of the device's locale.

## [1.0.8] - 2026-04-29

### Added

- **`Common/ODTVersion.psm1`** — single source of truth for the toolkit
  version string. Exports `Get-ToolkitVersion`, which returns the
  `$script:ToolkitVersion` constant defined at the top of the module.
  Every install / uninstall script now imports this module and resolves
  `$ScriptVersion` at runtime via `Get-ToolkitVersion`, so the
  `Script version : <x.y.z>` line in the CMTrace log header always
  matches the released version.

- **`Tests/Pester/ODTVersion.Tests.ps1`** — three tests:
  `Get-ToolkitVersion` returns a non-empty string, the value is
  SemVer-shaped, and the value matches the most recent
  `## [x.y.z]` heading in `CHANGELOG.md`. The CHANGELOG cross-check
  pins the constant against the changelog so a release bump in one
  place that forgets the other is caught by CI.

### Changed

- **Every install / uninstall script now reads its version from
  `Get-ToolkitVersion`** instead of carrying its own `$ScriptVersion =
  '1.0.0'` literal. Touched: `M365Apps/Install-M365Apps.ps1`,
  `M365Apps/Uninstall-M365Apps.ps1`, `Visio/Install-Visio.ps1`,
  `Visio/Uninstall-Visio.ps1`, `Project/Install-Project.ps1`,
  `Project/Uninstall-Project.ps1`,
  `LanguagePacks/Install-LanguagePack.ps1`,
  `LanguagePacks/Uninstall-LanguagePack.ps1`. v1.0.0–v1.0.7 left these
  hard-coded at `1.0.0`, so the log header silently lied about which
  release was running on the device. Closed.

- **`.NOTES Version` headers across all source files now read
  `<see Common/ODTVersion.psm1>`** instead of the literal `1.0.0`. The
  module is the canonical version; the per-file headers are pointers.

- **`Start-ODTLogSession` parameter default** changed from `'1.0.0'` to
  `'<unknown>'`. Callers in this toolkit always pass an explicit value
  (now sourced from `Get-ToolkitVersion`); the default is now an honest
  sentinel for callers that forget rather than a stale literal.

- **`README.md` version badge** bumped to `1.0.8`.

## [1.0.7] - 2026-04-29

### Added

- **Per-product language pack status logging in
  `Install-LanguagePack.ps1` and `Uninstall-LanguagePack.ps1`.** Admins
  reading IME / CMTrace logs now see exactly which Click-to-Run
  products carry the language and which don't, mirroring the
  per-installed-product reasoning v1.0.6 introduced.
  - **Pre-action snapshot**: `Language pack 'nb-no' status:
    O365ProPlusRetail=installed, VisioProRetail=missing,
    ProjectProRetail=missing.` Surfaces the exact decision the script
    is about to make.
  - **Already-installed branch (install)**: `Language pack 'nb-no'
    already installed for every C2R product (O365ProPlusRetail,
    VisioProRetail, ProjectProRetail); skipping setup.exe.` Lists the
    covered products instead of just saying "already installed."
  - **Post-action snapshot**: `Post-install language pack status:
    O365ProPlusRetail=installed, VisioProRetail=installed,
    ProjectProRetail=installed.` (`Post-uninstall ... =removed` on the
    uninstall side.) Shows the result of the action and feeds the
    silent-failure detection.
  - **Silent-failure log line is now per-product**: instead of
    "language pack 'nb-no' for O365ProPlusRetail is not present," the
    error names the products that are still missing the language.

- **`Get-LanguagePackInstallationStatus`** in
  `Common/ODTOfficeState.psm1`. Returns
  `[pscustomobject]@{ LanguageID; Installed; PerProduct }` where
  `PerProduct` is an ordered hashtable keyed on `ProductReleaseIds`
  entry (including the `LanguagePack` pseudo-product if registered).
  This is what feeds the new status logs above. Exported from the
  module for reuse by future detection / audit scripts.

### Changed

- **`Test-LanguagePackInstalled` is now a thin wrapper around
  `Get-LanguagePackInstallationStatus`.** Functional identity for
  callers — the bool semantic is preserved — but the per-product
  computation lives in one place. Internal refactor only.

- **`Uninstall-LanguagePack.ps1` skip semantic narrowed to the
  TargetProduct.** Pre-v1.0.7 the uninstall would skip when the
  language was missing from *every* C2R product (the v1.0.6 aggregate
  bool). v1.0.7 checks the specific `-TargetProduct` instead, since
  the removal XML uses `<Product ID="$TargetProduct">` and only
  affects that product. New skip line: `Language pack 'nb-no' is not
  installed for VisioProRetail; uninstall is a no-op for this target.`
  Post-uninstall verification likewise checks the TargetProduct
  specifically.

- **Action-time log lines trimmed**: `Installing language pack: 'nb-no'
  for O365ProPlusRetail.` → `Installing language pack: 'nb-no'.` and
  `Removing language pack: 'nb-no' for O365ProPlusRetail.` →
  `Removing language pack: 'nb-no' from O365ProPlusRetail.` (uninstall
  keeps the target name because the action *is* per-product). The
  "for `<TargetProduct>`" suffix in the install line was technically
  misleading post-v1.0.6 — the LP install uses
  `Product ID="LanguagePack"` and spreads across every installed
  product, not just the matrix-validation target.

## [1.0.6] - 2026-04-29

### Fixed

- **`Install-LanguagePack.ps1` no longer skips the install when the
  language is present for one C2R product but missing for another.**
  Surfaced by v1.0.5 verification: on a machine with M365 Apps
  installed in nb-NO directly (creating `O365ProPlusRetail - nb-no`)
  and Visio in en-us (no `VisioProRetail - nb-no`), running
  `Install-LanguagePack.ps1 -LanguageID nb-no` short-circuited at the
  idempotency check and never invoked `setup.exe`. Visio's UI listed
  nb-NO (registered system-wide) but rendered en-US.

  Two coupled root causes in `Common/ODTOfficeState.psm1`:

  - `Get-InstalledLanguages` unconditionally added `ClientCulture` to
    its returned list, even when callers asked for a different
    `ProductId`. So `Get-InstalledLanguages -ProductId 'LanguagePack'`
    returned `ClientCulture` even when no `LanguagePack - <lang>`
    Uninstall key existed. v1.0.6 drops the unconditional add — the
    per-product Uninstall keys are the source of truth.

  - `Test-LanguagePackInstalled` checked two Uninstall-key shapes
    (`LanguagePack - <lang>` and `<TargetProduct> - <lang>`) and
    returned `$true` if either matched anywhere on the machine. That
    semantic conflates "the language is registered for the product I
    asked about" with "the language is fully deployed across every
    installed Office product." v1.0.6 rewrites the function to the
    latter semantic: iterate `$config.ProductReleaseIds`, check each
    product for the per-product Uninstall key, return `$true` only
    when every product has it. The `-TargetProduct` parameter is
    removed (vestigial under the new semantic; in-tree callers updated).

  Net effect: in the v1.0.5 scenario-2 case, `Test-LanguagePackInstalled`
  now correctly returns `$false` (Visio is missing nb-NO), the install
  proceeds, `setup.exe` runs with `Product ID="LanguagePack"`, the
  language spreads across all installed products, and Visio gains the
  per-product Uninstall key + UI rendering capability.

### Changed

- `Test-LanguagePackInstalled` API: `-TargetProduct` parameter removed.
  In-tree callers (`Install-LanguagePack.ps1`, `Uninstall-LanguagePack.ps1`,
  4 call sites total) updated. The script-level `-TargetProduct`
  parameter on the LP install/uninstall scripts stays — it's still used
  for language-matrix validation (`Assert-ODTLanguageSupported`) and
  for log messages.
- `Get-InstalledLanguages` no longer returns `ClientCulture` from its
  result. Behaviour change is observable but the only caller in the
  toolkit is `Test-LanguagePackInstalled` (rewritten above).
- ODTOfficeState test surface restructured: two `Get-InstalledLanguages`
  tests (existing collection + new "no ClientCulture leak" assertion),
  eight `Test-LanguagePackInstalled` tests covering the per-product
  semantic including a regression test mirroring v1.0.5 scenario 2.

## [1.0.5] - 2026-04-29

### Changed

- **Visio and Project base installs are now constant en-US**, regardless
  of base Microsoft 365 Apps culture. Other UI languages for Visio and
  Project ship as separate Win32 apps via the `LanguagePacks/` workflow,
  on top of the en-US base install — the same model the toolkit uses
  for Microsoft 365 Apps's non-primary languages. One base install per
  product, one canonical mechanism for adding languages on top.

  This replaces v1.0.3's multi-language culture-matching behaviour
  (install in every Office-installed culture, drop the three documented
  unsupported tags). It also replaces a v1.0.5 implementation drafted
  during development (a smart-fallback + matrix-fallback resolver) that
  was scoped, tested, and reviewed but rejected before shipping —
  surveying the design surfaced too many edge cases to justify the
  complexity:
    - LP installs flip `ClientCulture`, so "match the base culture"
      drifts from the original install culture over a device's lifetime.
    - The per-product Visio/Project supported-language matrix is
      partially aspirational (Microsoft documents some cultures as
      supported that still hit ODT 17002), so matrix-based decisions
      can't be trusted as a clean filter.
    - Distinguishing `ClientCulture` from the original install culture
      from the user's display preference is more state than a Win32
      install script should be tracking.

  Always-en-US plus LP overlays sidesteps every one of those failure
  modes. Visio/Project install scripts shrink back to the v1.0.0
  surface area: prereqs, base-install detection, channel
  reconciliation, `setup.exe`, post-install verification.

- `Resolve-VisioProjectLanguage` and its v1.0.3 plural variant
  `Resolve-VisioProjectLanguages` are removed from
  `Common/ODTLanguages.psm1`. The `$script:VisioProjectUnsupportedCultures`
  data is also removed. Local-only deletion: only `Install-Visio.ps1`
  and `Install-Project.ps1` ever called the function, both updated.

- `Visio/Configurations/visio-base.xml` and
  `Project/Configurations/project-base.xml`: the v1.0.1 `{{LanguageID}}`
  runtime-token placeholder reverts to a literal `<Language ID="en-us" />`.
  The `{{LanguageID}}` token registration in the build engine stays —
  it's still used by the LanguagePack template.

- `Install-Visio.ps1` / `Install-Project.ps1`: drop the resolver
  call, the language XML rewrite, the language disclosure log lines,
  and the `Import-Module ODTLanguages.psm1` line (no longer needed).
  Channel reconciliation, architecture-mismatch logging, prerequisite
  checks, base-install detection, and post-install verification are
  unchanged.

### Unchanged

- The v1.0.4 `Language` build-time token for Microsoft 365 Apps. M365
  Apps still resolves its primary UI language via `-Language` /
  `build-config.json`, validated against the language matrix at build
  time. This is independent of the Visio/Project decision and
  unaffected by v1.0.5.
- `Common/ODTOfficeState.psm1`'s widened `InstalledLanguages` regex
  from v1.0.3 — still useful for any consumer of the
  `InstalledLanguages` property (e.g. `Test-LanguagePackInstalled`),
  even though v1.0.5's Visio/Project install scripts no longer read it.
- `LanguagePacks/` workflow — unchanged. Same single-language-per-call
  model, now load-bearing as the canonical Visio/Project language
  mechanism.

## [1.0.4] - 2026-04-28

### Added

- **`Language` build-time token** — primary Microsoft 365 Apps UI
  language is now configurable via `-Language nb-no` on
  `Build-IntuneWinPackages.ps1` or `"Language": "nb-no"` in
  `build-config.json`, mirroring the existing `CompanyName` and
  `ExcludedApps` pattern. Replaces the previous "fork the toolkit and
  hand-edit `<Language ID="en-us"/>`" workflow. The token is **scalar
  by design** — the toolkit installs one base UI language, with
  additional UI languages shipped as separate Win32 apps via the
  `LanguagePacks/` workflow (load-bearing customization principle,
  unchanged since v1.0.0). Validated at build time against the
  Microsoft 365 Apps language matrix in `Common/ODTLanguages.psm1`;
  typo'd codes (e.g. `nb-NN`) fail the build before staging starts.
  Unset / null / empty falls back to `en-us`.

### Changed

- Token engine (`Build/Invoke-ProductStaging.ps1`) gains two
  additive features for `BuildTime` mode: an optional `Default` field
  (substituted when `Value` is null / empty / whitespace, instead of
  the existing line-strip semantic — required because `<Product>`
  cannot drop its `<Language>` child) and an optional `KnownValues`
  validator (rejects values that aren't in the registered set,
  symmetric with `ExcludedApps`'s array-mode validation). Existing
  tokens (`CompanyName`) are unaffected — both fields are optional
  and absent on tokens that don't register them.
- Build banner displays Default-substituted scalar tokens as
  `Language='en-us' (default)` rather than the old
  `<unset, line stripped>` text, which would have been misleading
  for tokens whose unset semantic is "use Default" rather than "drop".
- `M365Apps/Configurations/m365apps-base.xml`:
  `<Language ID="en-us" />` → `<Language ID="{{Language}}" />`.
  Header comment updated.
- `docs/customization.md` Section 1 rewritten to point at the new
  token rather than instructing admins to hand-edit XML; the
  load-bearing "single language by design" principle is preserved
  and re-stated in token vocabulary.

## [1.0.3] - 2026-04-28

### Changed

- **Visio and Project now install in every supported base culture, not
  just the primary.** Microsoft 365 Apps can have many UI languages
  installed at once (e.g. `nb-no + de-de + en-gb`); v1.0.1 only resolved
  the primary `ClientCulture` and silently single-language'd the
  add-on. The resolver is now plural — `Resolve-VisioProjectLanguage` →
  `Resolve-VisioProjectLanguages` — and partitions the full
  `InstalledLanguages` list into a supported install set and a dropped
  set. en-GB / fr-CA / es-MX entries are dropped (logged at severity 2);
  the remaining cultures all get a `<Language>` element in the staged
  XML. en-us fallback fires only when *every* base culture is
  unsupported.
- `Install-Visio.ps1` and `Install-Project.ps1` log `Dropped from <Visio
  /Project> install: en-gb (...)` (severity 2) when any base culture is
  filtered, plus the existing `Installing <Visio/Project> with
  languages: nb-no, de-de.` line. Both rewrites (language + channel)
  now share a single `[xml]$doc` parse and Save, eliminating the
  per-install double TEMP-file churn from v1.0.2.

### Fixed

- **`Get-OfficeConfiguration.InstalledLanguages` regex narrowness.**
  The pre-v1.0.3 filter `^[a-z]{2}-[a-z]{2}$` silently dropped
  3-letter primary tags (`chr-cher-us`, `prs-af`, `kok-in`) and
  script-tag languages (`az-latn-az`, `sr-latn-rs`) when enumerating
  per-language sub-key value names, leaving the resolver with a
  truncated input on multi-lingual installs that included those
  shapes. Widened to the canonical
  `^[a-z]{2,3}(-[a-z]{2,8}){1,3}$` BCP-47 pattern used elsewhere in
  the toolkit. New ODTOfficeState test pins the contract.

## [1.0.2] - 2026-04-28

### Changed

- **Install logs now disclose the language(s) being installed for each
  product**, on a single line immediately before `setup.exe /configure`.
  Admins reading IME / CMTrace logs can confirm the resolved deployment
  language without correlating to the staged XML.
  - `Install-M365Apps.ps1`: enumerates `<Language ID="...">` from the
    staged XML and logs `Installing M365 Apps with languages: en-us[, ...].`
    (or a severity-2 fallback if no languages are declared / the XML
    fails to parse).
  - `Install-Visio.ps1` / `Install-Project.ps1`: log
    `Installing Visio with language: 'nb-no' (matches base culture).`
    on the common path; on the v1.0.1 substitution path, the log fires
    at severity 2 with the full substitution reason. Replaces the
    earlier decision-time "Resolved Visio/Project language" line so
    the same fact isn't logged twice.
  - `Install-LanguagePack.ps1`: logs
    `Installing language pack: 'nb-no' for O365ProPlusRetail.`
  - `Uninstall-LanguagePack.ps1`: logs
    `Removing language pack: 'nb-no' for O365ProPlusRetail.` for
    symmetry with install.

## [1.0.1] - 2026-04-28

### Fixed

- **Visio / Project no longer fail to install when base Microsoft 365 Apps
  is in `en-GB`, `fr-CA`, or `es-MX`.** Microsoft 365 Apps supports those
  three cultures, but Visio and Project do not ship them as a separate
  base-culture install (per the
  [supported-languages page](https://learn.microsoft.com/microsoft-365-apps/deploy/overview-deploying-languages-microsoft-365-apps),
  footnote [1] under Visio/Project). Inheriting the base culture in those
  cases triggered the ODT
  `BOOTSTRAPPER_PREREQ-UnsupportedCulturesOnUnsupportedProducts`
  prerequisite (exit 1603, ~5–7 s, no install attempt).
  `Install-Visio.ps1` and `Install-Project.ps1` now resolve the language at
  install time via `Resolve-VisioProjectLanguage` (in
  `Common/ODTLanguages.psm1`), falling back to `en-us` for the three
  unsupported cultures and logging the substitution. All other base
  cultures pass through unchanged.

### Changed

- `Visio/Configurations/visio-base.xml` and
  `Project/Configurations/project-base.xml` now carry the runtime token
  `<Language ID="{{LanguageID}}" />` instead of a literal `en-us`. The
  install scripts substitute this placeholder against the resolved
  language; a custom `-ConfigurationFile` that hardcodes a `Language ID`
  is unaffected (the substitution is a no-op when the placeholder is
  absent).

## [1.0.0] - 2026-04-26

Initial public release. See [README.md](README.md) for the toolkit
overview and [docs/architecture.md](docs/architecture.md) for the
design decisions.
