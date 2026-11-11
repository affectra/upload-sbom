# Affectra SBOM upload

Uploads the SBOMs your build produces to Affectra, into the
release they describe. Affectra then shows which vulnerabilities affect that
release and lets you record what you assessed (VEX).

You name the release the way your pipeline knows it: **product**, optionally a
**variant**, and **version**. Whatever does not exist yet is created, so a new
version needs no setup in Affectra.

A variant is a build of the product that gets its own releases: a hardware revision
(`rev-b`), a platform (`linux-arm64`), an edition (`pro`) or a SKU. A product with a
single build doesn't need one; its releases go into the product's `default` variant.

## Usage

```yaml
on:
  push:
    tags: ["v*"]

jobs:
  sbom:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write   # lets the job prove to Affectra which repository it runs in
    steps:
      - uses: actions/checkout@v4
      # ... build, and write your SBOMs (Syft, cdxgen, Yocto, ESP-IDF, ...)
      - uses: affectra/upload-sbom@v2   # pin to a commit SHA in production
        with:
          url: https://affectra.example.com
          organization: acme
          product: Gateway
          variant: rev-b      # optional
          version: ${{ github.ref_name }}
          sbom: |
            build/sbom/*.cdx.json
```

Uploading the same file again changes nothing, so re-running a job is safe.

### Setup: trusted publishing (no secret)

1. In Affectra, as an admin of your organization: **Trusted publishers**, enter the
   repository (`owner/name`) and **Trust repository**. Optionally restrict it to a
   workflow file (`release.yml`), a ref pattern (`refs/tags/v*`) or a GitHub
   environment. For a private repository, also enter its IDs:
   `gh api repos/OWNER/NAME --jq '.owner.id, .id'`.
2. Give the job `permissions: id-token: write`, as above.

Each run gets a short-lived token from GitHub that names its repository, workflow
and ref; Affectra checks it against the organization's trusted publishers. Nothing is
stored in the repository, and Affectra's logs show which repository and run uploaded.
The repository is pinned by GitHub's IDs, so renaming it keeps it trusted and a new
repository under the old name does not inherit trust. Tokens from pull requests of
forks are never issued, so forks cannot upload.

Your Affectra instance must accept GitHub Actions tokens (self-hosted: set
`AFFECTRA_GITHUB_ACTIONS_AUDIENCE` to the URL workflows use). If its admin gives you
a different audience, pass it as `audience`.

### Setup: API key

For Affectra instances without trusted publishing, or when the repository cannot be
trusted directly:

1. In Affectra, as an admin of your organization: **API keys → Create**. Copy the
   key; it is shown once.
2. In your GitHub repository: **Settings → Secrets and variables → Actions →
   New repository secret**, name `AFFECTRA_API_KEY`.
3. Add `api-key: ${{ secrets.AFFECTRA_API_KEY }}` to the step. `id-token: write` is
   then not needed; a key always wins over the token.

Use one key per repository or pipeline, so you can revoke one without touching
the others. Keys and trusted publishers can create and upload, but not delete.

### Signing SBOMs

With `sign: true` the step signs each SBOM with [Sigstore](https://www.sigstore.dev)
(`cosign sign-blob`, keyless) and uploads the signature with it. The signing
certificate names this repository, workflow, ref and commit, and the signature is
recorded in Sigstore's public transparency log. Affectra checks it on upload and
marks the SBOM **signed** when one of your organization's trusted publishers
allows the run, so anyone can later prove which build produced the document.

```yaml
permissions:
  contents: read
  id-token: write   # for the signing certificate (and the upload, without api-key)

steps:
  - uses: sigstore/cosign-installer@v3
  - uses: affectra/upload-sbom@v2
    with:
      url: https://affectra.example.com
      organization: acme
      product: Gateway
      variant: rev-b
      version: ${{ github.ref_name }}
      sbom: build/sbom/*.cdx.json
      sign: true
```

Signing works with an API key too; the signature, not the credential, says who
built the document. If you sign in an earlier step, leave `sign` off: a
`<file>.sigstore.json` next to an SBOM (`cosign sign-blob --new-bundle-format
--bundle sbom.cdx.json.sigstore.json sbom.cdx.json`) is uploaded as its signature,
and `*.sigstore.json` files are never uploaded as SBOMs.

#### SBOM attestations

GitHub's [`actions/attest-sbom`](https://github.com/actions/attest-sbom) signs a
statement that an SBOM describes your build outputs (firmware images, by digest).
Save its bundle as the SBOM's `.sigstore.json` and Affectra verifies it like a
signature, and also records which files the SBOM describes:

```yaml
permissions:
  contents: read
  id-token: write
  attestations: write

steps:
  # ... build dist/firmware.bin and dist/sbom.cdx.json
  - uses: actions/attest-sbom@v4
    id: attest
    with:
      subject-path: dist/firmware.bin
      sbom-path: dist/sbom.cdx.json
  - run: cp "$BUNDLE" dist/sbom.cdx.json.sigstore.json
    env:
      BUNDLE: ${{ steps.attest.outputs.bundle-path }}
  - uses: affectra/upload-sbom@v2
    with:
      # url, organization, product, variant, version as above
      sbom: dist/sbom.cdx.json
```

Leave `sign` off, or it replaces the attestation with a plain signature. Only JSON
SBOMs can be attested. Affectra accepts attestations from public repositories: in
private ones GitHub signs them with its own Sigstore instance, which Affectra does not
check yet.

Your organization can require signatures (**Trusted publishers → Accept only SBOMs
signed by a trusted repository**). Unsigned uploads then fail with 403.

### Build provenance

[`actions/attest-build-provenance`](https://github.com/actions/attest-build-provenance)
signs a statement that this workflow run built your firmware images (SLSA v1
provenance). Pass its bundle as `provenance` and Affectra lists each image on the
release's **Firmware** tab with the run that built it and the SBOMs that describe it:

```yaml
steps:
  # ... build dist/firmware.bin, attest its SBOM as above
  - uses: actions/attest-build-provenance@v4
    id: provenance
    with:
      subject-path: dist/firmware.bin
  - run: cp "$BUNDLE" dist/firmware.provenance.sigstore.json
    env:
      BUNDLE: ${{ steps.provenance.outputs.bundle-path }}
  - uses: affectra/upload-sbom@v2
    with:
      # url, organization, product, variant, version as above
      sbom: dist/sbom.cdx.json
      provenance: dist/firmware.provenance.sigstore.json
```

The bundles go to the same release after the SBOMs. Affectra verifies them like SBOM
signatures, and refuses provenance whose contents don't match its signing certificate.
They count against the organization's signature requirement as well. As for SBOM
attestations, only public repositories work for now. This needs an Affectra version
with build provenance (ADR 0024). On an older one the step fails after the SBOM upload
and says so.

## Inputs

| Input | Required | |
|---|---|---|
| `url` | yes | Your Affectra instance. Must be `https://` (plain `http://` only for `localhost`). |
| `organization` | yes | Your organization's slug, as in its URLs. Must trust this repository, or be the API key's organization. |
| `api-key` | no | Organization API key, always from a secret. Leave it out to use the job's GitHub OIDC token. |
| `audience` | no | Audience of the GitHub OIDC token. Defaults to `url`. |
| `product` | yes | Product name. Created if missing. |
| `variant` | no | Variant of that product (hardware revision, platform, edition, SKU). Created if missing. Empty: the product's `default` variant. |
| `version` | yes | Release version. Created if missing. |
| `sbom` | yes | Files to upload, one path or glob per line. `**` matches any depth. A line that matches nothing fails the step. |
| `provenance` | no | Build provenance bundles (`actions/attest-build-provenance`'s `bundle-path`), one path or glob per line, uploaded to the same release after the SBOMs. A line that matches nothing fails the step. |
| `released-at` | no | Release date in RFC 3339 (`2026-11-05T12:00:00Z`), used only when the release is created. |
| `sign` | no | `true` signs each SBOM with cosign and uploads the signature. Needs cosign 2.4+ and `id-token: write`. Default `false`. |

Formats are detected: CycloneDX 1.2–1.6 (JSON or XML), SPDX 2.x (JSON or
tag-value), SPDX 3.0 (JSON-LD), up to 64 MiB per file.

## Outputs

| Output | |
|---|---|
| `release-id` | ID of the release |
| `release-url` | Link to the release in the Affectra web app |
| `sbom-ids` | IDs of the uploaded SBOMs, one per line, in file order |
| `attestation-ids` | IDs of the uploaded build provenance, one per line, in file order |

The step also writes a job summary with each file's result and a link to the
release.

## What you will see

- **A warning** when the step created a product or a named variant. This is
  expected the first time; after that it usually means a typo in the workflow.
  Delete the stray product in Affectra and fix the name.
- **A notice** when it created a release (a new version).
- **Warnings** Affectra found in a document (an invalid PURL, a dependency on an
  unknown component, ...). The upload still succeeds.
- **A warning** when an SBOM is signed by a repository or workflow your
  organization does not trust. It is stored as "signed, untrusted".
- **An error**, failing the step, when the key or token is rejected (401), the key
  belongs to another organization or the organization does not trust this
  repository, workflow or ref (404), a file is not a supported SBOM or its
  signature does not verify (400), the organization requires signed SBOMs (403), the job
  has neither `api-key` nor `id-token: write`, or Affectra is unreachable (after
  retries).

Vulnerabilities appear on the release once Affectra has matched the components,
usually within a minute; the step does not wait for that.

## Rate limits

Affectra limits how fast an organization can upload. When it answers `429 Too Many
Requests`, the step waits for the `Retry-After` header (seconds; 30 if missing or not a
number) and tries the file once more. If Retry-After is over 300 seconds it does not wait,
and if the second try is also refused it fails with Affectra's message. Space out
uploads or send fewer, larger jobs if you hit this often. Connection errors and 5xx answers
are retried up to four times with a short backoff.

## Runners

GitHub-hosted Linux, macOS and Windows runners work as they are. Self-hosted
runners need `bash`, `curl` and `jq`.

## Other CI systems

The action is one HTTP request per file; any CI can do the same:

```sh
curl --fail-with-body -H "Authorization: Bearer $AFFECTRA_API_KEY" \
  -H "Content-Type: application/octet-stream" --data-binary @sbom.cdx.json \
  "https://affectra.example.com/v1/orgs/acme/sbom-uploads?product=Gateway&variant=rev-b&version=1.4.0"
```

URL-encode the names; leave out `variant` for the default variant. The response is
JSON: the SBOM, the product, variant and release, and `new` telling which of them the upload created.

With a signature, send both as `multipart/form-data`:

```sh
cosign sign-blob --yes --new-bundle-format --bundle sbom.sigstore.json sbom.cdx.json
curl --fail-with-body -H "Authorization: Bearer $AFFECTRA_API_KEY" \
  -F sbom=@sbom.cdx.json -F sigstore_bundle=@sbom.sigstore.json \
  "https://affectra.example.com/v1/orgs/acme/sbom-uploads?product=Gateway&variant=rev-b&version=1.4.0"
```

Affectra accepts signatures from GitHub Actions runs (the certificate must name the
repository by its numeric IDs).

Build provenance goes to the same release names, as the bundle itself:

```sh
curl --fail-with-body -H "Authorization: Bearer $AFFECTRA_API_KEY" \
  -H "Content-Type: application/json" --data-binary @firmware.provenance.sigstore.json \
  "https://affectra.example.com/v1/orgs/acme/attestation-uploads?product=Gateway&variant=rev-b&version=1.4.0"
```

## From v1

v2 renames the input `hardware-revision` to `variant` and makes it optional. Rename the
input in your workflow and change `@v1` to `@v2`; your existing releases keep their
names. Affectra refuses uploads that still send `hardware_revision` (400), so a
workflow left on v1 fails instead of uploading into the default variant.

## Development

`action.yml` runs `upload.sh` (bash, curl, jq; cosign for `sign: true`). CI runs `shellcheck upload.sh test/run.sh` and `test/run.sh`
(upload.sh against a fake server in `test/fake_server.py`; needs python3).
Without `api-key`, the script fetches the job's OIDC token from
`$ACTIONS_ID_TOKEN_REQUEST_URL` (fresh for each file, since tokens are short-lived).
The end-to-end test against a running Affectra stack is in the Affectra repository's
`e2e` job, which uses this action from `main`.

Releasing: tag `v1.2.3` and push it, then move the major tag for a final release
(`git tag -f v1 && git push -f origin v1`). Never move a version tag. Breaking
changes to inputs or outputs need a new major version (`v2`).
