# `build-config.json` examples

Ready-to-copy examples for the four shapes a rollout usually takes. Pick the
closest one, copy it to `build-config.json` in the repository root, and edit
the real values:

```powershell
Copy-Item .\docs\examples\build-config.en-gb.json .\build-config.json
```

`build-config.json` is gitignored, so your organisation's values never end up
in a commit. The canonical annotated template with every token documented is
[`build-config.example.json`](../../build-config.example.json) in the root —
these files are scenarios, that one is the reference.

| File | Base language | Shape |
|------|---------------|-------|
| [`build-config.en-us.json`](build-config.en-us.json) | `en-us` | Single language, toolkit default |
| [`build-config.en-gb.json`](build-config.en-gb.json) | `en-gb` | Single language, non-default |
| [`build-config.european-multi.json`](build-config.european-multi.json) | `en-gb` | One base + five LanguagePack apps |
| [`build-config.norwegian.json`](build-config.norwegian.json) | `nb-no` | One base + one LanguagePack app |

Keys beginning with `_` are commentary. JSON has no comment syntax, and the
build only ever reads the three registered token names, so anything else in
the file is ignored — that is what makes the explanatory keys safe to leave in
place.

## The one thing to know before you start

**`Language` is a scalar, not a list.** There is no `Languages` array, and a
JSON array fails the build:

```json
{ "Language": ["nb-no", "nn-no"] }
```

```
Invoke-XmlTokenSubstitution: token 'Language' value 'nb-no nn-no' is not in
the registered KnownValues set ...
```

The failure is immediate and happens before anything is staged. Microsoft 365
Apps installs **one** base UI language; every additional language is a separate
Intune Win32 app built from `LanguagePacks/`, reusing the same `.intunewin`
with different command parameters.

That split exists because each extra UI language adds roughly 300–400 MB to
the payload **every** device downloads. Baking five languages into the base
package would make every device pay for all five, on top of the ~2.8 GB the
base install already costs — which is the ESP timing consideration covered in
[`../troubleshooting.md`](../troubleshooting.md#office-install-is-slow-20-minutes---where-did-the-time-go).

The base language also sets the Shell UI — Start menu shortcuts, right-click
menus, tooltips — and Microsoft requires an uninstall and reinstall of Office
to change it afterwards. Language packs can be added and removed freely. So
when the choice is genuinely close, make the base the one that is hardest to
change for the most people.

## Verifying what you built

The `Language` token defaults to `en-us` when unset, and packages built for
different languages are indistinguishable from the outside. Three places state
the resolved value:

- the build banner: `Build-time tokens : ... Language='en-gb'`
- section 7 of the generated `Build\Output\M365Apps\M365Apps-IntuneConfig.md`
- on the client: `Installing M365 Apps with languages: en-gb.`

`Tests\Pester\BuildConfigExamples.Tests.ps1` keeps every file here valid JSON
with a language that is actually in the matrix, so a typo in an example
cannot be copied into a real deployment.

## Related

- [`../customization.md`](../customization.md) — every token, and the
  CLI-over-config resolution order
- [`../language-matrix.md`](../language-matrix.md) — which languages each
  product supports, and which documented tags still fail in practice
- [`../intune-deployment.md`](../intune-deployment.md) — creating the
  LanguagePack Win32 apps the multi-language examples refer to
