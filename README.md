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
    steps:
      - uses: actions/checkout@v4
      # ... build, and write your SBOMs (Syft, cdxgen, Yocto, ESP-IDF, ...)
      - uses: schmidtfx/upload-sbom@v1   # pin to a commit SHA in production
        with:
          url: https://exposa.example.com
          organization: acme
          api-key: ${{ secrets.EXPOSA_API_KEY }}
          product: Gateway
          hardware-revision: rev-b
          version: ${{ github.ref_name }}
          sbom: |
            build/sbom/*.cdx.json
```

Uploading the same file again changes nothing, so re-running a job is safe.

### Setup

1. In Exposa, as an admin of your organization: **API keys → Create**. Copy the
   key; it is shown once.
2. In your GitHub repository: **Settings → Secrets and variables → Actions →
   New repository secret**, name `EXPOSA_API_KEY`.

Use one key per repository or pipeline, so you can revoke one without touching
the others. API keys can create and upload, but not delete.

## Inputs

| Input | Required | |
|---|---|---|
| `url` | yes | Your Exposa instance. Must be `https://` (plain `http://` only for `localhost`). |
| `organization` | yes | Your organization's slug, as in its URLs. Must be the API key's organization. |
| `api-key` | yes | Organization API key. Always from a secret. |
| `product` | yes | Product name. Created if missing. |
| `hardware-revision` | yes | Hardware revision of that product. Created if missing. |
| `version` | yes | Release version. Created if missing. |
| `sbom` | yes | Files to upload, one path or glob per line. `**` matches any depth. A line that matches nothing fails the step. |
| `released-at` | no | Release date in RFC 3339 (`2026-11-05T12:00:00Z`), used only when the release is created. |

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
- **An error**, failing the step, when the key is wrong (401), the key belongs to
  another organization (404), a file is not a supported SBOM (400), or Exposa is
  unreachable (after retries).

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

## Development

`action.yml` runs `upload.sh` (bash, curl, jq). CI runs `shellcheck upload.sh`.
The end-to-end test against a running Exposa stack is in the Exposa repository's
`e2e` job, which uses this action from `main`.

Releasing: tag `v1.2.3` and push it, then move the major tag for a final release
(`git tag -f v1 && git push -f origin v1`). Never move a version tag. Breaking
changes to inputs or outputs need a new major version (`v2`).
