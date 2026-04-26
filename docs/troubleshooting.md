# Troubleshooting

Symptoms, causes, and resolutions for the common failures we've seen with
this toolkit. Most of these are really *Click-to-Run* / *ODT* / *Intune*
bugs rather than toolkit bugs — which is a useful framing when
troubleshooting.

When in doubt, start here:

```powershell
# Jump to the log folder and tail every relevant log.
cd C:\ProgramData\M365AppsDeploy\Logs
Get-ChildItem *.log | Sort-Object LastWriteTime -Descending
# Open the most recent ones in CMTrace or OneTrace.
```

### ODT native logs (for deep debugging only)

The toolkit does **not** redirect ODT's native logs. They land in
`%TEMP%` on the client by default, with names matching
`%TEMP%\<ComputerName><timestamp>.log` (plus sibling `stream`
logs). Only reach for these when the wrapper log is insufficient - 99%
of the time the wrapper log under `C:\ProgramData\M365AppsDeploy\Logs\`
already tells you what you need.

```powershell
# SYSTEM-context %TEMP% when running under Intune:
$systemTemp = "$env:windir\Temp"
Get-ChildItem $systemTemp -Filter "$env:COMPUTERNAME*.log" |
    Sort-Object LastWriteTime -Descending | Select-Object -First 5

# Interactive-user %TEMP% when running manually:
Get-ChildItem $env:TEMP -Filter "$env:COMPUTERNAME*.log" |
    Sort-Object LastWriteTime -Descending | Select-Object -First 5
```

ODT log content is verbose (every step of every file download,
integrity check, and MSI operation). Open in CMTrace / OneTrace and
filter by severity or component rather than reading top-to-bottom.

## Exit codes reference

| Exit | Meaning (from the toolkit's perspective)                                                           |
|------|------------------------------------------------------------------------------------------------------|
| 0    | Success                                                                                              |
| 1602 | User cancelled (not possible with `Display Level="None"`; if you see this, something set the level) |
| 1603 | Generic install failure — inspect ODT logs                                                           |
| 1618 | Another install is already in progress — Intune will retry                                           |
| 1641 | Success, reboot initiated                                                                            |
| 3010 | Success, reboot required                                                                             |
| 17000| ODT failed to start (very rare, indicates setup.exe corruption)                                      |
| 17001| ODT rejected the configuration XML as invalid                                                        |
| 17002| ODT reported a failure during install/uninstall — see ODT logs                                       |
| 17003| ODT queued but could not run (usually network to Office CDN)                                         |

The Install / Uninstall scripts translate these into human-readable
messages before writing them to the product log.

## "setup.exe returned 0 but the product is not installed"

Message appears in the product log as severity 3, and the script exits
17002. This is a **silent ODT failure** — `setup.exe` exited successfully
without actually installing anything.

Known causes:

1. **CDN reachability**. Devices behind a strict proxy can talk to
   `setup.exe` but not to `officecdn.microsoft.com`. Confirm the endpoints
   in
   [Microsoft 365 URLs and IP ranges](https://learn.microsoft.com/microsoft-365/enterprise/urls-and-ip-address-ranges)
   are whitelisted.
2. **Channel conflict**. Attempting to install Visio on a different
   channel than Office. The Install scripts warn about this at severity 2;
   if you see that warning, fix the XML to match the existing channel.
3. **Architecture conflict**. 64-bit Office + 32-bit Visio XML. The scripts
   now flag this at severity 3 before even running setup.exe. Match the
   architectures.
4. **Language not in Visio/Project matrix**. For language packs, confirm
   the combination in `docs/language-matrix.md`. The Install script
   should reject invalid combinations early, but if you're bypassing the
   validator, this is what you'll see.

## "Language not available"

Symptom: language pack install completes with exit 0 but the detection
script reports "not installed". Sometimes accompanied by ODT writing
"We couldn't install the language" to its log.

Root cause: the combination of `(TargetProduct, LanguageID)` is not
supported by ODT for the specified channel. The matrix varies over time
and across channels.

Fix:

1. Check `docs/language-matrix.md` for the current expected matrix.
2. Compare with
   [Microsoft's official language matrix](https://learn.microsoft.com/deployoffice/overview-deploying-languages-microsoft-365-apps).
3. If Microsoft lists the language as supported but it's still failing,
   try:
   - Using `Current` channel temporarily to see if it's channel-specific
   - Waiting a week — new languages sometimes lag a release on
     `MonthlyEnterprise`
4. If the language is confirmed unsupported for the product, either:
   - Switch the user group to a supported language, or
   - Install a full language pack (larger) instead of proofing-only, or
     vice-versa, depending on which matrix covers the code.

### Known example: en-gb on Visio

`en-gb` is documented as supported for Visio but several Visio builds
over the past two years have rejected it with "Language not available".

Current workaround:

- Test `en-gb` on your Visio channel in a lab before deploying broadly.
- If it fails, drop `en-gb` from the `$script:VisioLanguages` array in
  `Common/ODTLanguages.psm1` so the validator rejects it early, and use
  `en-us` as the Visio language instead.

## Detection returns the wrong result

### False positive (detection says installed but it's not)

Almost always caused by a **legacy MSI Office** leaving behind an
Uninstall key with a `DisplayName` like "Microsoft Office 2016". Any
detection script that does `Get-ChildItem Uninstall | Where DisplayName
-match 'Microsoft Office'` will false-positive on these.

Our detection scripts are immune — they read
`HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration\ProductReleaseIds`
directly. If you see false positives, you're running a different detection
script. Confirm the Intune Win32 app is pointing at the right
`Detect-*.ps1`.

### False negative (detection says not installed but it is)

1. Confirm the machine has finished the install. Office deploys can take
   30+ minutes; Intune sometimes runs detection before that completes.
2. Check the `ClickToRun\Configuration` key exists:
   ```powershell
   Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' |
       Select ProductReleaseIds, VersionToReport, Platform, UpdateChannel
   ```
3. If the key exists but the product ID is different from what the
   detection script expects, verify the product ID matches the Intune
   app. Common mix-up: `VisioStdRetail` vs `VisioProRetail`.

## Intune marks install as failed but the log shows success

Usually one of:

1. **Return code `17002` not listed as a failure code in the Win32 app
   config**. Re-read `docs/intune-deployment.md` — you need `17002 =
   Failed` in the return-codes table so silent failures propagate.
2. **Detection script parameterisation**. If you use the generic
   `Detect-LanguagePack.ps1` as the detection script directly, Intune
   calls it with no parameters and it errors. Use a per-(language,
   product) wrapper script. See `docs/intune-deployment.md`.
3. **Exit code collision**. Intune Win32 apps by default treat any
   non-zero exit as failure. If your wrapper script re-throws with a
   generic PowerShell error, the exit code gets mangled. The toolkit's
   scripts all call `exit <code>` explicitly — don't modify that.

## Install runs during user sign-in and locks them out

Two likely causes:

1. **ESP timeout too short**. 15-30 minutes is typical for a first Office
   install. Set the ESP "Block device use" timeout to ≥ 60 minutes.
2. **Office is not a Required app during ESP**. If it's Available instead,
   it won't block sign-in but also won't install until the user triggers
   it. Make Office Required for ESP.

## `setup.exe did not exit within 60 minutes and was terminated`

Toolkit safety timeout in `Invoke-ODTSetup`. Indicates either:

- Genuinely slow CDN or network
- Corrupt `setup.exe` stuck in a loop
- Another install already in progress (see the 1618 section below —
  the toolkit no longer pre-checks for this; ODT's own mutex handles it)

Fix:

- Investigate network first (run `Test-NetConnection officecdn.microsoft.com -Port 443` on the device).
- Delete any `Office15`, `Office16`, or ODT temp folders in `%ProgramData%\Microsoft\ClickToRun\`.
- Re-run with `-UseEvergreenSetup` to force a fresh ODT binary.
- Bump `-TimeoutMinutes` on the `Invoke-ODTSetup` call if your environment
  genuinely needs > 60 minutes (edit `Common/ODTInvoke.psm1`).

## "Another installation is already in progress" (exit 1618, or 0-1018 / 17003-2031 / 2035-0)

**What it means**: another ODT or Windows Installer operation on the
device is holding the global install mutex. The toolkit does **not**
pre-check for this — ODT's own concurrency handling is authoritative,
and a wrapper-side pre-check was false-positive-prone
(`OfficeClickToRun.exe` is the C2R background service, not an install
in progress). When another install truly is in flight, setup.exe
returns 1618 (or one of the related codes above) and the wrapper log
reports:

```
Result         : Failed (another install in progress).
```

### Likely causes

1. **Windows Update is installing something.** Wait for it, or check
   `services.msc → Windows Update`.
2. **Another Intune Win32 app is installing.** Intune serialises Win32
   apps, but edge cases exist — especially during first-sync /
   Enrollment Status Page when multiple apps race.
3. **A concurrent ODT run** from a sibling Install-*.ps1 (e.g. Visio
   install fired while the M365 Apps install was still winding down).
4. **Another software deployment tool** (Chocolatey, Winget, Ninite,
   SCCM/ConfigMgr client) is installing something else right now.

### Resolution

- The scripts do **not** retry 1618 themselves. Intune will retry the
  Win32 app on its own schedule. That is usually the correct outcome.
- If 1618 keeps firing on every retry: kill any long-running non-Intune
  installers on the device, let Windows Update finish, or look for a
  stuck `setup.exe` / `msiexec.exe` in Task Manager and terminate it.
- Do not add a pre-flight "is another install running?" check to the
  toolkit. ODT already does this better via its global mutex and we
  get the accurate exit code back either way. (See
  [`docs/architecture.md`](architecture.md#concurrency-is-delegated-to-odt-no-pre-flight-check).)

## OST / profile corruption after migration from MSI

`RemoveMSI` in our base XML cleans up legacy MSI Office, but **user
data** (Outlook PST/OST, Word custom dictionaries, templates) can
sometimes get confused by the migration.

Not a toolkit issue — this is how Office migration works. Guidance:

- Back up `%LOCALAPPDATA%\Microsoft\Outlook\*.ost` before migration
- First Outlook launch after migration will rebuild the OST from Exchange
  (can take time on large mailboxes)
- Custom dictionaries live in
  `%APPDATA%\Microsoft\UProof\CUSTOM.DIC` and usually survive migration
- Ribbon / QAT customisations live in
  `%LOCALAPPDATA%\Microsoft\Office\Word.officeUI` (etc.) and survive

## "Uninstall-M365Apps removed Visio and Project too"

### What happened

If you ran the uninstall **with `-RemoveAll`**, that's the documented
nuclear-cleanup path: Office, Visio, Project, every language pack, and
the C2R engine all go in one pass. The behaviour is intentional but
loud — see `architecture.md` "Uninstall semantics" for the rationale.

If you ran it **without `-RemoveAll`**, the default is surgical:
`Uninstall-M365Apps.ps1` (no switch) removes only
`O365ProPlusRetail` plus the `LanguagePack` accessory product.
Visio and Project are left intact. If Visio and Project did
disappear, check the log header for the mode marker below — the
script was likely invoked with `-RemoveAll`.

### How to know which mode ran

The first line of the session in
`C:\ProgramData\M365AppsDeploy\Logs\M365Apps-Uninstall.log` records
the mode:

```
Uninstall mode: SURGICAL (default): O365ProPlusRetail + LanguagePack only
Uninstall mode: NUCLEAR (-RemoveAll): full C2R stack including Visio / Project
```

### Recovering Visio / Project after a nuclear uninstall

ODT does not ship a "restore from previous state" mechanism. Reinstall
each product:

```powershell
# After the device has Office back via Install-M365Apps.ps1:
.\Visio\Install-Visio.ps1
.\Project\Install-Project.ps1
```

Each add-on install picks up channel and architecture from the freshly
installed Office automatically.

### Intune Win32 app uninstall command

The Microsoft 365 Apps Win32 app's **uninstall command** in Intune
should be the surgical default — never `-RemoveAll` in a default
deployment, or unassigning Office from a user automatically rips
Visio and Project off the device too:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File Uninstall-M365Apps.ps1
```

Admins who want nuclear cleanup do it manually or as a separate,
explicitly-named Intune app.

## How to get help

1. Attach the relevant product log from
   `C:\ProgramData\M365AppsDeploy\Logs\` to your issue.
2. Attach the matching native ODT log from `%TEMP%` (or
   `C:\Windows\Temp` for SYSTEM-context Intune installs) — see the
   [ODT native logs section above](#odt-native-logs-for-deep-debugging-only)
   for the exact filename pattern. The toolkit doesn't redirect ODT
   native logs; reach for them only when the wrapper log is
   insufficient.
3. Include the output of:
   ```powershell
   Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' |
       Select-Object ProductReleaseIds, Platform, UpdateChannel, VersionToReport, ClientCulture
   ```
4. Note the Intune device ID (from
   <https://intune.microsoft.com> → Devices) so we can correlate
   Intune's side of the story.
