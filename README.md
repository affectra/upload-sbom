# Affectra SBOM upload

Uploads the SBOMs your build produces to [Affectra](https://affectra.eu), into the
release they describe. You name the release by **product**, optionally a **variant**,
and **version**. Whatever does not exist yet is created, so a new version needs no
setup. Re-running a job is safe: uploading the same file again changes nothing.

## Quick start

With trusted publishing, which needs no secret. An admin of your organization trusts
the repository once, under **Trusted publishers** in Affectra.

```yaml
on:
  push:
    tags: ["v*"]

permissions: {}

jobs:
  sbom:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write # lets the job prove to Affectra which repository it runs in
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      # ... build, and write your SBOMs (Syft, cdxgen, Yocto, ESP-IDF, ...)
      - uses: affectra/upload-sbom@07cf6e5ce7a6d2dec0b49e6f527df5882f137111 # v2.2.0
        with:
          organization: acme
          product: Gateway
          version: ${{ github.ref_name }}
          sbom: build/sbom/*.cdx.json
```

This uploads to the hosted service, `https://api.affectra.eu`. For your own Affectra
instance, add `url:` with its API address.

Required inputs:

| Input | |
|---|---|
| `organization` | Your organization's slug, as in its URLs |
| `product` | Product name. Created if missing |
| `version` | Release version. Created if missing |
| `sbom` | Files to upload, one path or glob per line |

### A firmware SBOM and an AI BOM

A release that ships a machine learning model can have the model's AI BOM (CycloneDX
ML-BOM, or SPDX 3 with the AI and Dataset profiles) next to the firmware SBOM. Both are
SBOMs to this action: list them in `sbom`, one per line, and they go to the same release.

```yaml
      - uses: affectra/upload-sbom@07cf6e5ce7a6d2dec0b49e6f527df5882f137111 # v2.2.0
        with:
          organization: acme
          product: Door camera
          version: ${{ github.ref_name }}
          sbom: |
            build/sbom/firmware.cdx.json
            build/sbom/person-detect.aibom.cdx.json
```

Affectra shows the model card, the datasets and the models it was derived from on the
release's **AI models** tab.

### A signed model

To show that the shipped model is the one you trained, sign the trained model's files
with OpenSSF model signing (`model_signing`, 1.0 or later) in the workflow, keyless with
the job's OIDC token, and pass the signature as `model-signature`. It goes to the same
release after the SBOMs and the build provenance. Affectra takes whole files hashed with
SHA-256 (the default), up to 1024 files and 1 MiB per signature.

```yaml
    permissions:
      contents: read
      id-token: write
    steps:
      # ... train or download the model into build/model ...
      - run: |
          pip install model-signing==1.1.1
          model_signing sign sigstore --use_ambient_credentials --signature build/model.sig build/model
      - uses: affectra/upload-sbom@v2
        with:
          organization: acme
          product: Door camera
          version: ${{ github.ref_name }}
          sbom: |
            build/sbom/firmware.cdx.json
            build/sbom/person-detect.aibom.cdx.json
          model-signature: build/model.sig
```

Affectra lists the signed files on the release's **Artifacts** tab, "Model files, signed by"
this workflow, and links them to the model in the AI BOM by digest.

## Documentation

Everything else is in the Affectra documentation:

- [Upload SBOMs from GitHub Actions](https://docs.affectra.eu/guides/upload-github-actions/):
  trusted publishing, API keys, variants, signing, build provenance, model signatures, build
  configs, errors.
- [Inputs and outputs](https://docs.affectra.eu/reference/upload-sbom/): every input
  and output of this action.
- [AI models and datasets](https://docs.affectra.eu/guides/ai-models/): AI BOMs, and
  finding the releases that ship a model or were trained on a dataset.

## Development

`action.yml` runs `upload.sh` (bash, curl, jq; cosign for `sign: true`). CI runs `shellcheck upload.sh test/run.sh` and `test/run.sh`
(upload.sh against a fake server in `test/fake_server.py`; needs python3).
Without `api-key`, the script fetches the job's OIDC token from
`$ACTIONS_ID_TOKEN_REQUEST_URL` (fresh for each file, since tokens are short-lived).
The end-to-end test against a running Affectra stack is in the Affectra repository's
`e2e` job, which uses this action from `main`.

The Affectra documentation renders the inputs and outputs from a copy of `action.yml`
at a release tag (`just docs-sync-action <tag>` in the Affectra repository), so change
an input's description here and tag a release for the docs to pick it up.

Releasing: tag `v1.2.3` and push it, then move the major tag for a final release
(`git tag -f v1 && git push -f origin v1`). Never move a version tag. Breaking
changes to inputs or outputs need a new major version (`v2`).
