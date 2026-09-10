# Customization guide

This toolkit ships with sensible defaults but every organisation will need
to tweak something. This page lists the concrete places to edit, in order
from most-commonly-changed to least.

> ℹ️ Some customisations are now **build-time tokens** rather than
> manual XML edits. Setting a token via `-CompanyName` (or
> `build-config.json`) keeps your fork from drifting against
> upstream and avoids "Your Company" leakage in production.
> The current token list is in
> [Section 4 — Org-specific values via build-time tokens](#4-org-specific-values-via-build-time-tokens).

## 1. Primary Office UI language

**Token**: `Language` (build-time scalar — see [Section 4](#4-org-specific-values-via-build-time-tokens)).

Set the primary Microsoft 365 Apps UI language via CLI flag or
`build-config.json` — no XML edit required:

```powershell
.\Build\Build-IntuneWinPackages.ps1 -Language nb-no
```

Or persisted across every build (`build-config.json` is gitignored;
copy from `build-config.example.json`):

```json
{ "Language": "nb-no" }
```

Ready-to-copy files for the common rollout shapes — single language,
multi-country European, and Norwegian Bokmal + Nynorsk — are in
[`docs/examples/`](examples/README.md).

Unset / null / empty falls back to **`en-us`** (the toolkit baseline).
The build engine validates the value against the Microsoft 365 Apps
language matrix in `Common/ODTLanguages.psm1` and fails loudly on
typos before staging — no more "Language not available" surprises at
install time.

Re-upload `Build\Output\M365Apps\Install-M365Apps.intunewin` to Intune
when you next deploy.

> **Confirm the resolved language before uploading.** The token defaults to
> `en-us` when unset, and packages for different languages are
> indistinguishable from the outside — same file name, similar size, same
> detection script. Two places state it:
>
> - the build banner: `Build-time tokens : ... Language='en-gb'`, or
>   `Language='en-us' (default)` when nothing was set;
> - section 7 of the generated `Build\Output\<Product>\<Product>-IntuneConfig.md`,
>   which reads the language back out of the staged XML.
>
> On the client, the install log names it before setup.exe runs:
> `Installing M365 Apps with languages: en-gb.`
>
> For a non-default language, prefer `build-config.json` over the CLI flag so
> the value is applied to every build.

**Scope of the `Language` token: Microsoft 365 Apps only.** Visio
and Project base installs are always en-US — independent of the
`Language` token, independent of the base Microsoft 365 Apps culture.
Additional UI languages for Visio / Project ship as separate Win32
apps via the `LanguagePacks/` workflow on top of the en-US base, the
same model the toolkit uses for M365 Apps's non-primary languages.
One base install per product, one canonical mechanism for adding
languages on top. See [`docs/language-matrix.md`](language-matrix.md#why-we-do-not-use-matchinstalled)
for the rationale.

**The `Language` token is scalar by design** — the toolkit installs
**one** base UI language for M365 Apps and ships additional UI
languages as separate Win32 apps via the `LanguagePacks/` workflow,
so user groups only receive the languages they need. The token
registration enforces this: there is no `Languages` (plural) array.
If you find yourself wanting to multi-Language the base XML by hand,
you almost certainly want the `LanguagePacks/` workflow instead.

## 2. Update channel

Available channel names (from Microsoft Learn):

- `MonthlyEnterprise` (default) — monthly updates, 60-day security lag
- `Current` — fastest public channel, weekly feature updates
- `SemiAnnual` — twice-yearly feature updates
- `SemiAnnualPreview` — pre-release of SemiAnnual
- `BetaChannel` — insider preview
- `CurrentPreview` — pre-release of Current

Change `Channel="MonthlyEnterprise"` to your choice in:

- `M365Apps/Configurations/m365apps-base.xml`
- `Visio/Configurations/visio-base.xml`
- `Project/Configurations/project-base.xml`

**Channels must match across Office, Visio, and Project on the same
device**, so change all three together.

## 3. Excluded apps

The default exclusion set is the **opinionated seven-app modern
default**:

- `Access` — Windows-only, no Mac parity, modern orgs route those workloads to SharePoint Lists / Power Apps / Dataverse.
- `Bing` — Microsoft Search in Bing default-search-engine extension.
- `Groove` — the old OneDrive for Business client.
- `Lync` — the retired Skype for Business.
- `OneDrive` — deployed separately via the OneDrive bootstrapper in modern tenants.
- `Publisher` — on Microsoft's retirement track, excluded from new SKUs.
- `Teams` — deployed via its own bootstrapper / MSIX in modern tenants.

OneNote is intentionally **kept** — the UWP retirement made the
desktop OneNote the default again.

This list is now a **build-time token** (`ExcludedApps`), not a
manual XML edit. See [Section 4](#4-org-specific-values-via-build-time-tokens)
for how to override it. The default lives literally in the
`<Product>` block of `M365Apps/Configurations/m365apps-base.xml`,
between begin/end marker comments. The build engine validates
every ID against the canonical Microsoft set and fails loudly on
unknown IDs (ODT silently ignores invalid IDs, so a typo would
otherwise ship a working-looking package that installs Access on
every endpoint).

Full list of valid app IDs (Microsoft canonical set, accepted by the
build engine):
<https://learn.microsoft.com/microsoft-365-apps/deploy/office-deployment-tool-configuration-options#excludeapp-element>
plus `Bing` (Microsoft Search in Bing extension).

## 4. Org-specific values via build-time tokens

Every base XML has tokens of the form `{{TokenName}}` in the
attribute values that vary per organisation. These are resolved at
**build time** by `Build\Build-IntuneWinPackages.ps1`, not at
install time on the client.

The OCT parallel: leave a token value blank and the toolkit behaves
the way `config.office.com` behaves when you leave a field blank —
the corresponding line is **omitted** from the staged XML. No
`Your Company` placeholder ever leaks into a production install,
even on a freshly forked toolkit you build with no flags.

### Resolution order

1. CLI parameter on `Build-IntuneWinPackages.ps1` (highest priority).
2. `build-config.json` at the repo root (gitignored — see
   `build-config.example.json` as the template).
3. Unset (no substitution; the line containing the placeholder is
   removed from the staged XML).

### Currently supported tokens

| Token          | Mode              | XML element controlled                                                                                                                                         | Effect when unset / null                                                                                                                            |
|----------------|-------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------|
| `CompanyName`  | `BuildTime` (scalar)        | `<Setup Name="Company" Value="..."/>` in M365 Apps / Visio / Project base XMLs. Controls the "registered to" string in Office's Account pane.                 | The `<Setup>` line is dropped during staging; if the surrounding `<AppSettings>` block becomes empty, it is stripped too.                          |
| `Language`     | `BuildTime` (scalar)        | `<Language ID="..."/>` inside the `<Product>` block of `M365Apps/Configurations/m365apps-base.xml`. Single tag (one base UI language, by design). Validated against the Microsoft 365 Apps language matrix at build time; typo'd codes fail the build. | Falls back to the registered default `en-us` (substituted into the staged XML). *The "line stripped" semantic does NOT apply* — `<Product>` requires a `<Language>` child. |
| `ExcludedApps` | `ArrayExpansion`  | The default `<ExcludeApp>` set inside the `<Product>` block of `M365Apps/Configurations/m365apps-base.xml`. Replace-not-supplement (see note below).           | The seven-app **modern default** baked literally into the source XML is preserved unchanged. *The "line stripped" semantic does NOT apply here* — the source XML carries a real default, not a placeholder. |

> ℹ️ `ExcludedApps` differs from `CompanyName` in two important
> ways. **First**, the unset path is "use the default from the XML"
> rather than "strip the line" — there's no stripped-line semantic
> for arrays. **Second**, a value is a full **replacement**, not an
> addition: setting `ExcludedApps = ["Access"]` produces *only*
> Access in the exclusion list, dropping the other six defaults.
> If you want default-plus-one, write out every entry you want.
> Unknown IDs fail the build before staging starts (ODT silently
> ignores invalid IDs).

### Examples

```powershell
# Scalar token: bake an org name into the staged XMLs.
.\Build\Build-IntuneWinPackages.ps1 -CompanyName "Contoso Ltd"

# Scalar token: set the primary M365 Apps UI language (validated against the matrix).
.\Build\Build-IntuneWinPackages.ps1 -Language nb-no

# Array token: re-include Access (drop it from the exclusion list).
.\Build\Build-IntuneWinPackages.ps1 -ExcludedApps Bing,Groove,Lync,OneDrive,Publisher,Teams

# Array token: install every Office app on the device (no exclusions).
.\Build\Build-IntuneWinPackages.ps1 -ExcludedApps @()

# Persist for every build (build-config.json is gitignored):
Copy-Item build-config.example.json build-config.json
# edit build-config.json:
#   { "CompanyName": "Contoso Ltd", "Language": "nb-no", "ExcludedApps": ["Bing","Groove","Lync"] }
.\Build\Build-IntuneWinPackages.ps1
```

### Adding a new token

The token registration table is `Get-DefaultBuildTokens` in
`Build\Invoke-ProductStaging.ps1`. Adding a token is one line in that
table plus an optional CLI parameter on
`Build-IntuneWinPackages.ps1`. The substitution engine **hard-fails**
on any `{{...}}` placeholder it finds in source XMLs that is not
registered, so typos surface at build time rather than silently
shipping a broken XML to a client.

### Note on Runtime tokens

`{{OfficeClientEdition}}`, `{{Channel}}`, `{{LanguageID}}` in
`LanguagePacks/Configurations/languagepack-template.xml` are
**Runtime** tokens — they are resolved by `Install-LanguagePack.ps1`
against the live device state, not at build time. They are listed in
the same registration table as `Mode = 'Runtime'` so the build
engine recognises them as pass-through and the post-substitution
scan accepts them. Don't try to set them via CLI / config file.

## 5. Licensing model (shared / device / user)

Defaults assume **per-user licensing** with auto-activation off (Office
activates when the user signs in). Override in the base XMLs via
`<Property>` elements:

| Property                    | Default | When to change                                         |
|-----------------------------|---------|--------------------------------------------------------|
| `SharedComputerLicensing`   | `0`     | Set to `1` for RDS / AVD / Cloud PC hosts              |
| `DeviceBasedLicensing`      | `0`     | Set to `1` for device-licensed kiosks                  |
| `SCLCacheOverride`          | `0`     | Set to `1` + `SCLCacheOverrideDirectory` for RDS       |
| `AUTOACTIVATE`              | `0`     | Set to `1` for KMS / MAK scenarios                     |
| `FORCEAPPSHUTDOWN`          | `TRUE`  | Leave alone — required for unattended installs         |

> 🔭 These are candidates for future build-time tokens (with the same
> "unset = line removed" behaviour as `CompanyName`). They aren't
> tokenised yet, so for now the customisation is a manual XML edit
> in your fork.

## 5b. OEM-preinstalled consumer Office

Some vendor images ship a *consumer* Click-to-Run Office, most commonly
`O365HomePremRetail`. `<RemoveMSI />` does not remove it — Microsoft
documents RemoveMSI as covering Windows Installer products only — so it
remains registered alongside `O365ProPlusRetail` after the enterprise
install.

Opt in per deployment, in the Intune install command:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File Install-M365Apps.ps1 -RemovePreinstalledConsumerOffice
```

Off by default: removing software is opt-in. When set, and only when one of
the listed SKUs is actually present, the script runs a separate ODT pass
against `M365Apps\Configurations\m365apps-remove-consumer.xml` first. A
failed removal is logged as a warning and the install continues.

To add a SKU, edit **both**:

- `$ConsumerProductIds` near the top of `M365Apps\Install-M365Apps.ps1`
- the `<Remove>` block in `M365Apps\Configurations\m365apps-remove-consumer.xml`

`Tests\Pester\ConsumerOfficeRemoval.Tests.ps1` fails if the two drift apart.

The removal XML is deliberately scoped to named products rather than
`<Remove All="TRUE" />`, so a device that legitimately has enterprise Office,
Visio or Project installed is left alone.

## 5c. Install progress logging

`Install-M365Apps.ps1 -ProgressIntervalSeconds <n>` controls how often a
progress line is written while setup.exe runs. Default 30; `0` disables it.

Drop to 15 when you are actively investigating a slow install — the
Click-to-Run phase breakdown resolves to one interval. See
[`docs/troubleshooting.md`](troubleshooting.md) for how to read the output.

## 6. Log path

Default: `C:\ProgramData\M365AppsDeploy\Logs\`.

If your organisation locks down `C:\ProgramData\` (common in highly
restricted environments), override via the `-LogPath` parameter on every
script. This has to be set consistently across install, uninstall, and
detection commands.

Example install command for Intune:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File Install-M365Apps.ps1 -LogPath "C:\Logs\M365AppsDeploy"
```

Make sure the override path is writable by SYSTEM.

## 7. Rebranding the toolkit directory name

The name `M365AppsDeploy` appears in:

- Log paths (`C:\ProgramData\M365AppsDeploy\Logs\`)
- Session-header strings in `ODTLogging.psm1`

Rebrand with a single search-and-replace across the repo. Use something
like:

```powershell
Get-ChildItem -Recurse -Include *.ps1,*.psm1,*.xml,*.md |
  ForEach-Object {
      (Get-Content $_.FullName -Raw).Replace('M365AppsDeploy','AcmeOfficeDeploy') |
          Set-Content $_.FullName -Encoding UTF8
  }
```

Don't forget to also rename the top-level folder if you fork the repo.

## 8. User-specific AppSettings

Office configuration can pre-seed user-level defaults. Add `<User>`
elements inside `<AppSettings>`:

```xml
<AppSettings>
  <Setup Name="Company" Value="{{CompanyName}}" />
  <User Key="software\microsoft\office\16.0\excel\options"
        Name="defaultformat" Value="51"
        Type="REG_DWORD" App="excel16" Id="L_SaveExcelfilesas" />
  <User Key="software\microsoft\office\16.0\word\options"
        Name="defaultformat" Value="" Type="REG_SZ"
        App="word16" Id="L_SaveWordfilesas" />
</AppSettings>
```

Enumerate every setting you want via
<https://config.office.com> and export the XML, then copy the `<User>`
lines into the relevant base XML. These settings apply at first user
sign-in to the Office apps.

The `<Setup Name="Company" .../>` line above is the build-time
`{{CompanyName}}` token (Section 4). The `<User>` lines are static
XML edits — if you find yourself wanting to vary them per-fork in
the same way, register a new token in the build pipeline rather
than maintaining a per-fork edit by hand.

## 9. External configuration hosting

If you prefer to centrally manage the ODT XMLs rather than editing them
per-fork, host each configuration in Azure Blob Storage (or similar with
HTTPS) and point the install scripts at it:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File Install-M365Apps.ps1 -ConfigurationURL "https://your-storage.blob.core.windows.net/odt/m365apps-base.xml"
```

The URL must be HTTPS. The script retries 3 times with exponential
backoff on transient failures.

## 10. Prerequisite-check thresholds

`Common/ODTPrerequisites.psm1` has one tunable: minimum free disk space.
Default 5 GB (configurable via the wrapper's `-MinimumFreeGB` parameter).

If your test VMs fail the disk check, either provision more storage or
lower the threshold in the module. Do not drop below 3 GB — Office
installs at ~3 GB, with update cache headroom.

## 11. Product variants

If your org uses **Standard** editions rather than Professional:

| From               | To                | Change in                          |
|--------------------|-------------------|-------------------------------------|
| `VisioProRetail`   | `VisioStdRetail`  | Visio base.xml, Install/Detect/Uninstall |
| `ProjectProRetail` | `ProjectStdRetail`| Project base.xml, Install/Detect/Uninstall |

For Visio/Project scripts, you'll need to find/replace the literal product
IDs (they're in the `$ProductId` variable at the top of each script and
in the XMLs).

## 12. What you should not change

- The **CMTrace log format** — tooling depends on it.
- The **post-install registry verification step** — this catches silent
  setup.exe failures (ODT occasionally returns 0 without actually
  installing the product). Without it, a silent ODT failure ships as
  "success" to Intune and only the failing detection verdict surfaces.
- The **`<Remove All="FALSE">` scoping** in Visio and Project
  uninstall XMLs — changing to `All="TRUE"` would wipe Office when
  someone uninstalls Visio.
- The **language matrix validation** in the LanguagePack scripts —
  removing it re-introduces the Visio "Language not available" silent
  failure.

If you find yourself wanting to change these, open an issue first to
discuss.
