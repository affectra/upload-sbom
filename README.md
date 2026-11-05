# Exposa SBOM upload

Uploads the SBOMs your build produces to Exposa, into the
release they describe. Exposa then shows which vulnerabilities affect that
release and lets you record what you assessed (VEX).

You name the release the way your pipeline knows it: **product**, **hardware
revision** and **version**. Whatever does not exist yet is created, so a new
version needs no setup in Exposa.

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
      id-token: write   # lets the job prove to Exposa which repository it runs in
    steps:
      - uses: actions/checkout@v4
      # ... build, and write your SBOMs (Syft, cdxgen, Yocto, ESP-IDF, ...)
      - uses: schmidtfx/upload-sbom@v1   # pin to a commit SHA in production
        with:
          url: https://exposa.example.com
          organization: acme
          product: Gateway
          hardware-revision: rev-b
          version: ${{ github.ref_name }}
          sbom: |
            build/sbom/*.cdx.json
```

Uploading the same file again changes nothing, so re-running a job is safe.

### Setup: trusted publishing (no secret)

1. In Exposa, as an admin of your organization: **Trusted publishers**, enter the
   repository (`owner/name`) and **Trust repository**. Optionally restrict it to a
   workflow file (`release.yml`), a ref pattern (`refs/tags/v*`) or a GitHub
   environment. For a private repository, also enter its IDs:
   `gh api repos/OWNER/NAME --jq '.owner.id, .id'`.
2. Give the job `permissions: id-token: write`, as above.

Each run gets a short-lived token from GitHub that names its repository, workflow
and ref; Exposa checks it against the organization's trusted publishers. Nothing is
stored in the repository, and Exposa's logs show which repository and run uploaded.
The repository is pinned by GitHub's IDs, so renaming it keeps it trusted and a new
repository under the old name does not inherit trust. Tokens from pull requests of
forks are never issued, so forks cannot upload.

Your Exposa instance must accept GitHub Actions tokens (self-hosted: set
`EXPOSA_GITHUB_ACTIONS_AUDIENCE` to the URL workflows use). If its admin gives you
a different audience, pass it as `audience`.

### Setup: API key

For Exposa instances without trusted publishing, or when the repository cannot be
trusted directly:

1. In Exposa, as an admin of your organization: **API keys → Create**. Copy the
   key; it is shown once.
2. In your GitHub repository: **Settings → Secrets and variables → Actions →
   New repository secret**, name `EXPOSA_API_KEY`.
3. Add `api-key: ${{ secrets.EXPOSA_API_KEY }}` to the step. `id-token: write` is
   then not needed; a key always wins over the token.

Use one key per repository or pipeline, so you can revoke one without touching
the others. Keys and trusted publishers can create and upload, but not delete.

### Signing SBOMs

With `sign: true` the step signs each SBOM with [Sigstore](https://www.sigstore.dev)
(`cosign sign-blob`, keyless) and uploads the signature with it. The signing
certificate names this repository, workflow, ref and commit, and the signature is
recorded in Sigstore's public transparency log. Exposa checks it on upload and
marks the SBOM **signed** when one of your organization's trusted publishers
allows the run, so anyone can later prove which build produced the document.

```yaml
permissions:
  contents: read
  id-token: write   # for the signing certificate (and the upload, without api-key)

steps:
  - uses: sigstore/cosign-installer@v3
  - uses: schmidtfx/upload-sbom@v1
    with:
      url: https://exposa.example.com
      organization: acme
      product: Gateway
      hardware-revision: rev-b
      version: ${{ github.ref_name }}
      sbom: build/sbom/*.cdx.json
      sign: true
```

Signing works with an API key too; the signature, not the credential, says who
built the document. If you sign in an earlier step, leave `sign` off: a
`<file>.sigstore.json` next to an SBOM (`cosign sign-blob --new-bundle-format
--bundle sbom.cdx.json.sigstore.json sbom.cdx.json`) is uploaded as its signature,
and `*.sigstore.json` files are never uploaded as SBOMs.

Your organization can require signatures (**Trusted publishers → Accept only SBOMs
signed by a trusted repository**). Unsigned uploads then fail with 403.

## Inputs

| Input | Required | |
|---|---|---|
| `url` | yes | Your Exposa instance. Must be `https://` (plain `http://` only for `localhost`). |
| `organization` | yes | Your organization's slug, as in its URLs. Must trust this repository, or be the API key's organization. |
| `api-key` | no | Organization API key, always from a secret. Leave it out to use the job's GitHub OIDC token. |
| `audience` | no | Audience of the GitHub OIDC token. Defaults to `url`. |
| `product` | yes | Product name. Created if missing. |
| `hardware-revision` | yes | Hardware revision of that product. Created if missing. |
| `version` | yes | Release version. Created if missing. |
| `sbom` | yes | Files to upload, one path or glob per line. `**` matches any depth. A line that matches nothing fails the step. |
| `released-at` | no | Release date in RFC 3339 (`2026-11-05T12:00:00Z`), used only when the release is created. |
| `sign` | no | `true` signs each SBOM with cosign and uploads the signature. Needs cosign 2.4+ and `id-token: write`. Default `false`. |

Formats are detected: CycloneDX 1.2–1.6 (JSON or XML), SPDX 2.x (JSON or
tag-value), SPDX 3.0 (JSON-LD), up to 64 MiB per file.

## Outputs

| Output | |
|---|---|
| `release-id` | ID of the release |
| `release-url` | Link to the release in the Exposa web app |
| `sbom-ids` | IDs of the uploaded SBOMs, one per line, in file order |

The step also writes a job summary with each file's result and a link to the
release.

## What you will see

- **A warning** when the step created a product or a hardware revision. This is
  expected the first time; after that it usually means a typo in the workflow.
  Delete the stray product in Exposa and fix the name.
- **A notice** when it created a release (a new version).
- **Warnings** Exposa found in a document (an invalid PURL, a dependency on an
  unknown component, ...). The upload still succeeds.
- **A warning** when an SBOM is signed by a repository or workflow your
  organization does not trust. It is stored as "signed, untrusted".
- **An error**, failing the step, when the key or token is rejected (401), the key
  belongs to another organization or the organization does not trust this
  repository, workflow or ref (404), a file is not a supported SBOM or its
  signature does not verify (400), the organization requires signed SBOMs (403), the job
  has neither `api-key` nor `id-token: write`, or Exposa is unreachable (after
  retries).

Vulnerabilities appear on the release once Exposa has matched the components,
usually within a minute; the step does not wait for that.

## Runners

GitHub-hosted Linux, macOS and Windows runners work as they are. Self-hosted
runners need `bash`, `curl` and `jq`.

## Other CI systems

The action is one HTTP request per file; any CI can do the same:

```sh
curl --fail-with-body -H "Authorization: Bearer $EXPOSA_API_KEY" \
  -H "Content-Type: application/octet-stream" --data-binary @sbom.cdx.json \
  "https://exposa.example.com/v1/orgs/acme/sbom-uploads?product=Gateway&hardware_revision=rev-b&version=1.4.0"
```

URL-encode the names. The response is JSON: the SBOM, the product, hardware
revision and release, and `new` telling which of them the upload created.

With a signature, send both as `multipart/form-data`:

```sh
cosign sign-blob --yes --new-bundle-format --bundle sbom.sigstore.json sbom.cdx.json
curl --fail-with-body -H "Authorization: Bearer $EXPOSA_API_KEY" \
  -F sbom=@sbom.cdx.json -F sigstore_bundle=@sbom.sigstore.json \
  "https://exposa.example.com/v1/orgs/acme/sbom-uploads?product=Gateway&hardware_revision=rev-b&version=1.4.0"
```

Exposa accepts signatures from GitHub Actions runs (the certificate must name the
repository by its numeric IDs).

## Development

`action.yml` runs `upload.sh` (bash, curl, jq; cosign for `sign: true`). CI runs `shellcheck upload.sh`.
Without `api-key`, the script fetches the job's OIDC token from
`$ACTIONS_ID_TOKEN_REQUEST_URL` (fresh for each file, since tokens are short-lived).
The end-to-end test against a running Exposa stack is in the Exposa repository's
`e2e` job, which uses this action from `main`.

Releasing: tag `v1.2.3` and push it, then move the major tag for a final release
(`git tag -f v1 && git push -f origin v1`). Never move a version tag. Breaking
changes to inputs or outputs need a new major version (`v2`).
