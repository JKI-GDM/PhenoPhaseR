# Releasing PhenoPhaseR

How a version is cut and archived. The chain is **Codeberg → GitHub → Zenodo**:
development happens on Codeberg, GitHub (`JKI-GDM/PhenoPhaseR`) is the mirror that
Zenodo watches, and each GitHub release is archived to Zenodo under the concept
DOI [10.5281/zenodo.18743008](https://doi.org/10.5281/zenodo.18743008), which
mints a new **version DOI** automatically.

## 0. Choose the version number

Semantic Versioning (`MAJOR.MINOR.PATCH`), applied to the **emitted-metadata
contract** as well as the code:

- **PATCH** (`x.y.Z`) — backwards-compatible fix, no schema/vocabulary change.
- **MINOR** (`x.Y.0`) — new vocabulary terms, or a change to which IRIs are
  emitted, with the R entry points unchanged. *(This release, v1.8.0.)*
- **MAJOR** (`X.0.0`) — an incompatible change to the R entry-point API.

> This release is **v1.8.0**: it adds the `fairagrodq:UncertaintyExpressionPrinciple`
> scheme and the `fairagrodq:expressedBy` axis, and migrates the spatial-uncertainty
> dimensions `dffp:`→`fairagrodq:` — new functionality plus a vocabulary change, so
> MINOR. A patch (1.7.3) would understate it.

## 1. Update the in-repo metadata

Set the new version consistently in:

- `CHANGELOG.md` — move the entry under a dated `## [1.8.0] - 2026-06-19` heading.
- `CITATION.cff` — `version: 1.8.0`, `date-released: "2026-06-19"`.
- `.zenodo.json` — `"version": "v1.8.0"` and the `isSupplementTo` GitHub
  `tree/v1.8.0` link.
- Any version string inside the code (e.g. a `PACKAGE_VERSION` constant or the
  version the builders stamp into `ro-crate-metadata.json`).

Quick consistency check:

```bash
grep -Rn "1\.8\.0" CHANGELOG.md CITATION.cff .zenodo.json
```

## 2. Validate before tagging

```bash
# JSON + YAML well-formedness
python3 -c "import json; json.load(open('.zenodo.json'))"
python3 -c "import yaml; yaml.safe_load(open('CITATION.cff'))"

# CITATION.cff schema (optional but recommended)
pip install --user cffconvert && cffconvert --validate

# rebuild a sample crate and re-validate the emitted metadata
Rscript -e 'source("build_phase_cog_ro_crate.R"); # ... build a small crate ...'
# then run your RO-Crate validator (e.g. roc-validator / rocrate-validator)
```

Re-run the consistency audit on a freshly built crate: confirm there are **no
dangling references**, that spatial-uncertainty dimensions are `fairagrodq:` and
`dct:isDefinedBy` Säurich (not `conformsTo` ISO), that `fairagrodq:expressedBy`
targets resolve to defined principle concepts, and that no `skos:closeMatch` to a
non-existent concept is asserted.

## 3. Commit and tag

```bash
git add CHANGELOG.md CITATION.cff .zenodo.json README.md RELEASE_NOTES_v1.8.0.md \
        dq_vocab_core.R dq_uncertainty_principles.R \
        build_phase_cog_ro_crate.R build_filtervariant_ro_crate.R

git commit -m "Release v1.8.0: fairagrodq spatial-uncertainty dimensions + expression-principle axis; isDefinedBy Säurich (drop ISO conformsTo overclaim)"

# annotated tag (Zenodo keys the release off the tag)
git tag -a v1.8.0 -m "PhenoPhaseR v1.8.0 — honest anchoring of spatial uncertainty; expression-principle axis"
```

If Codeberg is `origin` and GitHub is a second remote:

```bash
git push origin main --follow-tags          # Codeberg
git push github main --follow-tags           # GitHub mirror that Zenodo watches
```

(If GitHub is the only push target, a single `git push --follow-tags` suffices.)

## 4. Create the GitHub release (this triggers Zenodo)

On GitHub → **Releases → Draft a new release**:

- **Tag:** `v1.8.0`
- **Title:** `PhenoPhaseR v1.8.0`
- **Description:** paste `RELEASE_NOTES_v1.8.0.md`.

Publishing the release fires the Zenodo GitHub webhook. Zenodo creates a **new
version** under the existing concept record, applies the metadata from
`.zenodo.json`, and mints a **new version DOI** (e.g. `10.5281/zenodo.XXXXXXXX`).
The concept DOI `10.5281/zenodo.18743008` continues to resolve to the latest
version.

> The Zenodo ↔ GitHub integration must be enabled once for the repository
> (Zenodo → GitHub → flip the switch on `JKI-GDM/PhenoPhaseR`). It is already on
> for this repo if previous versions (≤ v1.7.2) were archived automatically.

## 5. After the DOI is minted

- Add the new **version DOI** to `CITATION.cff` under `identifiers:` (alongside
  the concept DOI) and, if you keep a version-specific badge, update it. Commit as
  a small follow-up (does not need its own release).
- Verify on the Zenodo record that the **license** (MIT), **creators/ORCID**,
  **keywords**, **related identifiers**, **grant** (DFG 501899475), and
  **community** (JKI) rendered correctly. The `.zenodo.json` `grants` and
  `license` fields in particular are worth eyeballing, since their accepted format
  has changed across Zenodo versions; if either does not render, set it once in
  the Zenodo web form and it will carry forward.
- Confirm the GitHub release shows **Software Heritage** and **OpenAIRE** badges
  once indexing completes.

## Notes

- **License.** The deposit is MIT (code). If a future version bundles
  documentation or data you wish to license separately, add a `LICENSE-CC-BY-4.0`
  and note the split in `README.md`; otherwise keep MIT throughout.
- **Immutability.** Never edit a published version's files. Corrections ship as a
  new version; superseded encodings (e.g. the old `dffp:` spatial-uncertainty
  IRIs) remain valid historical record in their original deposit.
