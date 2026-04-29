# Per-product language matrix

Microsoft 365 Apps, Visio, and Project each support a different (and
changing) set of language codes. This page documents the matrix used
by `Common/ODTLanguages.psm1` for pre-flight validation so admins
see a clear error before `setup.exe` is invoked.

> ℹ️ **Standalone Proofing Tools is not supported.** Spell-check
> in additional languages comes via the full Language Pack install
> for that language — Language Packs include proofing as part of
> the package. See
> [architecture.md](architecture.md#standalone-proofing-tools-not-supported)
> for the rationale.

The live Microsoft reference is:

- [Overview of deploying languages for Microsoft 365 Apps](https://learn.microsoft.com/deployoffice/overview-deploying-languages-microsoft-365-apps)
- [Language identifiers for Office](https://learn.microsoft.com/deployoffice/overview-deploying-languages-microsoft-365-apps#languages-culture-codes-and-companion-proofing-languages)

If you believe a combination should work but the toolkit rejects it, check
that page; if Microsoft has added support, update the matrix in
`Common/ODTLanguages.psm1` and this document together.

## Microsoft 365 Apps (`O365ProPlusRetail`)

Supports the broadest language set — everything Microsoft ships for
Click-to-Run Office:

```
af-za        am-et        ar-sa        as-in        az-latn-az
be-by        bg-bg        bn-bd        bn-in        bs-latn-ba
ca-es        ca-es-valencia              chr-cher-us    cs-cz
cy-gb        da-dk        de-de        el-gr        en-gb
en-us        es-es        es-mx        et-ee        eu-es
fa-ir        fi-fi        fil-ph       fr-ca        fr-fr
ga-ie        gd-gb        gl-es        gu-in        ha-latn-ng
he-il        hi-in        hr-hr        hu-hu        hy-am
id-id        ig-ng        is-is        it-it        iu-latn-ca
ja-jp        ka-ge        kk-kz        km-kh        kn-in
ko-kr        kok-in       ku-arab-iq   ky-kg        lb-lu
lo-la        lt-lt        lv-lv        mi-nz        mk-mk
ml-in        mn-mn        mr-in        ms-my        mt-mt
my-mm        nb-no        ne-np        nl-nl        nn-no
nso-za       or-in        pa-in        pl-pl        prs-af
ps-af        pt-br        pt-pt        quc-latn-gt  quz-pe
rm-ch        ro-ro        ru-ru        rw-rw        sd-arab-pk
si-lk        sk-sk        sl-si        sq-al        sr-cyrl-ba
sr-cyrl-rs   sr-latn-rs   sv-se        sw-ke        ta-in
te-in        tg-cyrl-tj   th-th        ti-et        tk-tm
tn-za        tr-tr        tt-ru        ug-cn        uk-ua
ur-pk        uz-latn-uz   vi-vn        wo-sn        xh-za
yo-ng        zh-cn        zh-tw        zu-za
```

Use any of these with `Install-LanguagePack.ps1 -LanguageID <code>
-TargetProduct O365ProPlusRetail`.

## Visio Professional (`VisioProRetail` / `VisioStdRetail`)

Visio supports a **narrower** set. The toolkit validates against this
list:

```
ar-sa        bg-bg        cs-cz        da-dk        de-de
el-gr        en-gb        en-us        es-es        es-mx
et-ee        fi-fi        fr-ca        fr-fr        he-il
hi-in        hr-hr        hu-hu        id-id        it-it
ja-jp        kk-kz        ko-kr        lt-lt        lv-lv
nb-no        nl-nl        pl-pl        pt-br        pt-pt
ro-ro        ru-ru        sk-sk        sl-si        sr-latn-rs
sv-se        th-th        tr-tr        uk-ua        vi-vn
zh-cn        zh-tw
```

**`en-gb`, `fr-ca`, `es-mx` caveat:** these three tags appear in the
matrix above (Microsoft documents them as supported), but Visio does
not ship a full UI pack for any of them. v1.0.5 makes Visio/Project
base installs **always en-US** so admins never trip the
ODT-level prerequisite this caveat would otherwise produce, and
language-pack deployments fall back to en-US / fr-FR / es-ES strings
in Visio's UI for the same reason. See
[en-GB / fr-CA / es-MX language packs on Visio / Project](#en-gb--fr-ca--es-mx-language-packs-on-visio--project) below.

## Project Professional (`ProjectProRetail` / `ProjectStdRetail`)

Same list as Visio on Click-to-Run:

```
ar-sa        bg-bg        cs-cz        da-dk        de-de
el-gr        en-gb        en-us        es-es        es-mx
et-ee        fi-fi        fr-ca        fr-fr        he-il
hi-in        hr-hr        hu-hu        id-id        it-it
ja-jp        kk-kz        ko-kr        lt-lt        lv-lv
nb-no        nl-nl        pl-pl        pt-br        pt-pt
ro-ro        ru-ru        sk-sk        sl-si        sr-latn-rs
sv-se        th-th        tr-tr        uk-ua        vi-vn
zh-cn        zh-tw
```

## en-GB / fr-CA / es-MX language packs on Visio / Project

When you install the `en-gb`, `fr-ca`, or `es-mx` **language pack** on
a machine that already has Visio or Project, those products list the
language as installed in the Office Language Preferences UI — but
Visio and Project render their interface in `en-US`, `fr-FR`, or
`es-ES` respectively. Microsoft does not ship a full Visio / Project
UI pack for those three cultures (footnote [1] under Visio/Project
on the [supported-languages page](https://learn.microsoft.com/microsoft-365-apps/deploy/overview-deploying-languages-microsoft-365-apps)).

| Language pack installed | Word / Excel / etc. UI | Visio / Project UI |
|-------------------------|------------------------|--------------------|
| `en-gb`                 | en-GB                  | en-US              |
| `fr-ca`                 | fr-CA                  | fr-FR              |
| `es-mx`                 | es-MX                  | es-ES              |

This is downstream Microsoft behaviour, not a toolkit limitation. The
toolkit's `Install-LanguagePack.ps1` uses Microsoft's documented
`LanguagePack` pseudo-product (`Product ID="LanguagePack"` in the
rendered XML) so any language pack is applied across all installed
Office products that support it — Visio and Project pick it up, but
fall back to the parent culture for UI strings.

Proofing (spell-check, hyphenation, thesaurus) does install and work
for the requested culture across all products; only the UI strings
fall back in Visio / Project. Communicate this to end users ahead
of an `en-gb` / `fr-ca` / `es-mx` rollout.

v1.0.5 onwards: the base install for Visio / Project is always
en-US, so admins who don't push the language pack as a separate Win32
app never see this fallback. The fallback only surfaces when the
language pack is deployed on top.

## Proofing (spell-check) for non-primary languages

Install the full **Language Pack** for the target language. Language
Packs use `Product ID="LanguagePack"` (Microsoft's documented
pseudo-product) and include proofing — spellcheck, grammar,
thesaurus, hyphenation — alongside the partial UI translation. One
install, reliable outcome.

This toolkit does **not** ship a standalone `ProofingTools` product
because ODT's `Product ID="ProofingTools"` flow produces
inconsistent results on current M365 Apps builds: the registry
stub appears but Office does not reliably register the language's
proofing. Use the full Language Pack for that language instead.
See [architecture.md](architecture.md#standalone-proofing-tools-not-supported).

## Why we do **not** use `MatchInstalled`

ODT supports `<Language ID="MatchInstalled" />` as shorthand for "install
the add-on in every language the base Office install already has". This
looks convenient but it's unsafe for Visio / Project add-ons because:

1. The Office and Visio/Project language matrices are **not identical**.
   If the user has Office with `af-za` installed, `MatchInstalled` tells
   ODT to install Visio with `af-za` — which Visio does not support.
   ODT fails silently or returns an obscure error.
2. `MatchInstalled` behaviour has changed across ODT versions. Relying
   on it ties your deployment to specific ODT builds.
3. We want the installed language to be **explicit and auditable** in
   every deployment. Hidden derivation from existing state means
   "why does this device have Visio in German?" has no answer in the
   deployment config.

Instead: the install scripts read the current Office install's full
`InstalledLanguages` list, filter it through `Resolve-VisioProjectLanguages`
(drops `en-gb` / `fr-ca` / `es-mx`, falls back to `en-us` if every
base culture is unsupported), and pass **explicit** `<Language>`
elements to `setup.exe` — one per resolved BCP-47 code.

## Updating the matrix

If Microsoft adds support for a new language in Visio or Project:

1. Add the BCP-47 code to the appropriate `$script:VisioLanguages` /
   `$script:ProjectLanguages` array in `Common/ODTLanguages.psm1`.
2. Add the code to the corresponding table in this document.
3. Bump the CHANGELOG under an "Added" entry.
4. Test the new combination in the lab before relying on it in
   production — Microsoft's documentation sometimes precedes the actual
   CDN availability by a release.

If a language stops working (e.g. Microsoft removes it from Visio):

1. Remove the code from `Common/ODTLanguages.psm1`.
2. Remove the row from this document.
3. Bump the CHANGELOG under a "Changed" entry explaining the reason.
