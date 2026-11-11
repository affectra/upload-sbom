#!/usr/bin/env bash
# Uploads SBOM files to an Affectra release named by product, variant and
# version (POST /v1/orgs/{org}/sbom-uploads, ADR 0005 and ADR 0011), then
# build provenance bundles to the same release
# (POST /v1/orgs/{org}/attestation-uploads, ADR 0024).
#
# Settings come from the environment (action.yml sets them):
#   AFFECTRA_URL, AFFECTRA_ORG, AFFECTRA_PRODUCT, AFFECTRA_VARIANT (optional:
#   empty means the product's default variant), AFFECTRA_VERSION, AFFECTRA_SBOM (one path or glob per line),
#   AFFECTRA_PROVENANCE (optional; SLSA build provenance bundles, one path or
#   glob per line), AFFECTRA_RELEASED_AT (optional), AFFECTRA_SIGN (true: sign
#   each file with cosign; otherwise <file>.sigstore.json is sent if it
#   exists, ADR 0007),
#   and for authentication either
#   AFFECTRA_API_KEY or nothing: then the job's GitHub OIDC token is used
#   (needs `permissions: id-token: write`), with AFFECTRA_AUDIENCE as its
#   audience (default: AFFECTRA_URL).
# Needs bash, curl and jq; GitHub-hosted runners have all three. Signing
# needs cosign 2.4 or later.
#
# Outside GitHub Actions it works too; the workflow commands it prints
# (::error:: etc.) are then plain log lines.
set -euo pipefail

# --- GitHub workflow command helpers ---

# escape makes a value safe inside a workflow command.
escape() {
	local s=${1//'%'/'%25'}
	s=${s//$'\r'/'%0D'}
	s=${s//$'\n'/'%0A'}
	printf '%s' "$s"
}
# Properties (file=...) also need ':' and ',' escaped.
escape_prop() {
	local s
	s=$(escape "$1")
	s=${s//':'/'%3A'}
	s=${s//','/'%2C'}
	printf '%s' "$s"
}
error() { echo "::error${2:+ file=$(escape_prop "$2")}::$(escape "$1")"; }
warning() { echo "::warning${2:+ file=$(escape_prop "$2")}::$(escape "$1")"; }
notice() { echo "::notice::$(escape "$1")"; }
fail() {
	error "$1"
	exit 1
}

output() { # name value (value may span lines)
	[ -n "${GITHUB_OUTPUT:-}" ] || return 0
	local delim="AFFECTRA_$RANDOM$RANDOM$RANDOM"
	printf '%s<<%s\n%s\n%s\n' "$1" "$delim" "$2" "$delim" >>"$GITHUB_OUTPUT"
}
summary() { [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '%s\n' "$1" >>"$GITHUB_STEP_SUMMARY"; }

# --- check the settings ---

command -v curl >/dev/null || fail "curl is not installed on this runner"
command -v jq >/dev/null || fail "jq is not installed on this runner"

for v in AFFECTRA_URL AFFECTRA_ORG AFFECTRA_PRODUCT AFFECTRA_VERSION AFFECTRA_SBOM; do
	[ -n "$(printf '%s' "${!v:-}" | tr -d '[:space:]')" ] || fail "input ${v#AFFECTRA_} is empty"
done

case ${AFFECTRA_SIGN:-false} in
true) sign=1 ;;
false | "") sign=0 ;;
*) fail "input sign must be true or false, not \"$AFFECTRA_SIGN\"" ;;
esac
if [ "$sign" = 1 ]; then
	command -v cosign >/dev/null ||
		fail "sign: true needs cosign on the runner; add the step \"uses: sigstore/cosign-installer@v3\" before this one"
	[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] ||
		fail "sign: true needs the job's OIDC token: add \"permissions: id-token: write\" to the job"
fi

base=${AFFECTRA_URL%/}
case $base in
https://*) ;;
http://localhost | http://localhost:* | http://127.0.0.1 | http://127.0.0.1:* | http://\[::1\]*) ;;
*) fail "url must start with https:// (plain http only for localhost): $base" ;;
esac

uri() { jq -rn --arg v "$1" '$v | @uri'; }

# --- authentication: an API key, or the job's GitHub OIDC token ---

key=$(printf '%s' "${AFFECTRA_API_KEY:-}" | tr -d '[:space:]')
if [ -n "$key" ]; then
	auth=key
	# Secrets are masked already; this also covers a key passed another way.
	echo "::add-mask::$key"
	case $key in
	*[!A-Za-z0-9_-]*) fail "the API key has unexpected characters; pass the key exactly as Affectra showed it" ;;
	esac
elif [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
	auth=oidc
	audience=${AFFECTRA_AUDIENCE:-$base}
else
	fail "no credentials: give the job \"permissions: id-token: write\" (and trust this repository in Affectra under Trusted publishers), or pass api-key"
fi
variant=$(printf '%s' "${AFFECTRA_VARIANT:-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
query="product=$(uri "$AFFECTRA_PRODUCT")&version=$(uri "$AFFECTRA_VERSION")"
[ -z "$variant" ] || query+="&variant=$(uri "$variant")"
[ -z "$AFFECTRA_RELEASED_AT" ] || query+="&released_at=$(uri "$AFFECTRA_RELEASED_AT")"
org_base="$base/v1/orgs/$(uri "$AFFECTRA_ORG")"

# --- expand the file lists ---

# expand PATTERNS SKIP_SIGNATURES sets files to the files the patterns (one
# per line) match. With SKIP_SIGNATURES=1, *.sigstore.json is left out:
# signatures next to the SBOMs are not SBOMs themselves.
expand() {
	local line pattern f
	files=()
	shopt -s nullglob
	# ** needs bash 4; on bash 3 (macOS /bin/bash) it acts like *.
	shopt -s globstar 2>/dev/null || true
	while IFS= read -r line || [ -n "$line" ]; do
		pattern=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
		[ -n "$pattern" ] || continue
		# Split only on newlines; expand the glob.
		IFS=$'\n'
		# shellcheck disable=SC2206
		matches=($pattern)
		unset IFS
		[ ${#matches[@]} -gt 0 ] || fail "no file matches: $pattern"
		for f in "${matches[@]}"; do
			if [ "$2" = 1 ]; then
				case $f in *.sigstore.json) continue ;; esac
			fi
			[ -f "$f" ] || fail "not a file: $f"
			files+=("$f")
		done
	done <<<"$1"
	shopt -u nullglob
}

expand "$AFFECTRA_SBOM" 1
[ ${#files[@]} -gt 0 ] || fail "no SBOM files given"
sbom_files=("${files[@]}")
provenance_files=()
if [ -n "$(printf '%s' "${AFFECTRA_PROVENANCE:-}" | tr -d '[:space:]')" ]; then
	expand "$AFFECTRA_PROVENANCE" 0
	provenance_files=("${files[@]}")
fi

# --- upload ---

tmp=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/affectra.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
# Secrets go to curl through config files, not the command line, so they
# do not show in the runner's process list.
umask 077

# authorize writes the credential for the next upload. A GitHub OIDC token
# lives for minutes, so each file gets a fresh one.
authorize() {
	if [ "$auth" = key ]; then
		printf 'header = "Authorization: Bearer %s"\n' "$key" >"$tmp/auth"
		return
	fi
	printf 'header = "Authorization: Bearer %s"\n' "$ACTIONS_ID_TOKEN_REQUEST_TOKEN" >"$tmp/gh"
	local token
	token=$(curl --silent --show-error --fail --config "$tmp/gh" --retry 4 --connect-timeout 20 --max-time 60 \
		"$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$(uri "$audience")" | jq -r '.value // empty') ||
		fail "could not get an OIDC token from GitHub"
	[ -n "$token" ] || fail "GitHub returned no OIDC token"
	echo "::add-mask::$token"
	case $token in
	*[!A-Za-z0-9._-]*) fail "GitHub returned an unexpected OIDC token" ;;
	esac
	printf 'header = "Authorization: Bearer %s"\n' "$token" >"$tmp/auth"
}

repo=${GITHUB_REPOSITORY:-this repository}

# bundle_for prints the Sigstore bundle to upload with $1, or nothing.
bundle_for() {
	if [ "$sign" = 1 ]; then
		rm -f "$tmp/bundle.json"
		# Keyless: cosign gets the job's OIDC token itself; the certificate
		# names this repository, workflow and commit.
		cosign sign-blob --yes --new-bundle-format --bundle "$tmp/bundle.json" "$1" >/dev/null 2>"$tmp/cosign.log" || {
			cat "$tmp/cosign.log" >&2
			fail "cosign could not sign $1"
		}
		printf '%s' "$tmp/bundle.json"
	elif [ -f "$1.sigstore.json" ]; then
		printf '%s' "$1.sigstore.json"
	fi
}

# retry_after prints the seconds to wait from the Retry-After header in file $1
# (delta-seconds; a date or a missing header gives the default).
default_retry_wait=30 max_retry_wait=300
retry_after() {
	local v
	v=$(tr -d '\r' <"$1" | grep -i '^retry-after:' | tail -n 1 | cut -d: -f2- | tr -d '[:space:]') || true
	case $v in
	"" | *[!0-9]*) echo "$default_retry_wait" ;;
	# More digits than any sane wait: avoid overflow, over the cap anyway.
	???????*) echo $((max_retry_wait + 1)) ;;
	*) echo $((10#$v)) ;;
	esac
}

# post FILE URL CURL_ARGS... sends one upload and sets code, body and msg.
# It returns 1 when Affectra could not be reached (already reported), and
# exits on answers that would fail every other file too (401, 403, 404).
#
# Retries are done here, not by curl: curl --retry would also retry a 429,
# and without a cap on Retry-After. A 429 is retried once after Retry-After
# (ADR 0018); connection errors and 408/5xx up to 4 times with backoff.
post() {
	local f=$1 url=$2 rc rate_limited=0 transient=0 wait detail
	shift 2
	authorize
	while :; do
		rc=0
		code=$(curl --silent --show-error --config "$tmp/auth" \
			--connect-timeout 20 --max-time 600 \
			"$@" -D "$tmp/headers" -o "$tmp/response" -w '%{http_code}' \
			"$url") || rc=$?
		if [ "$rc" != 0 ]; then
			# 7 refused, 28 timeout, 52 empty reply, 56 receive failure
			case $rc in 7 | 28 | 52 | 56) [ "$transient" -lt 4 ] && {
				sleep $((1 << transient))
				transient=$((transient + 1))
				continue
			} ;; esac
			error "could not reach Affectra at $base" "$f"
			return 1
		fi
		case $code in
		408 | 500 | 502 | 503 | 504)
			[ "$transient" -lt 4 ] || break
			sleep $((1 << transient))
			transient=$((transient + 1))
			;;
		429)
			[ "$rate_limited" = 0 ] || break
			wait=$(retry_after "$tmp/headers")
			if [ "$wait" -gt "$max_retry_wait" ]; then
				warning "Affectra asked to wait ${wait}s (Retry-After), more than the ${max_retry_wait}s limit; not retrying" "$f"
				break
			fi
			notice "Affectra is rate limiting uploads (429); retrying $f once after ${wait}s"
			sleep "$wait"
			rate_limited=1
			;;
		*) break ;;
		esac
	done
	body=$(cat "$tmp/response")
	# Affectra answers errors as problem details (RFC 9457): print the English
	# detail and its code. Anything else (an older Affectra, a proxy's error
	# page) is printed as it is.
	msg=$body
	if [ "${code:0:1}" != 2 ] && detail=$(jq -er 'select(.detail | type == "string")
		| .detail + (if (.code | type) == "string" then " [" + .code + "]" else "" end)' <<<"$body" 2>/dev/null); then
		msg=$detail
	fi
	case $code in
	401)
		[ "$auth" = key ] && fail "Affectra rejected the API key (401). Is it revoked, or from another Affectra instance?"
		fail "Affectra rejected the GitHub OIDC token (401). Does this Affectra instance accept GitHub Actions tokens for audience \"$audience\"?"
		;;
	404)
		# The SBOMs went to this organization, so it exists and trusts this
		# run: the server predates build provenance.
		case $url in */attestation-uploads\?*) [ "$announced" = 1 ] &&
			fail "this Affectra instance does not accept build provenance yet (404); leave out provenance, or ask your Affectra admin to upgrade" ;;
		esac
		[ "$auth" = key ] && fail "organization \"$AFFECTRA_ORG\" not found for this API key (404). The key must belong to that organization."
		fail "organization \"$AFFECTRA_ORG\" does not trust $repo for this run (404). An admin adds it in Affectra under Trusted publishers; check its workflow, ref and environment restrictions (this run: ${GITHUB_WORKFLOW_REF:-unknown workflow})."
		;;
	403) fail "not allowed to upload (403): $msg" ;;
	esac
}

# announce reports, for the first successful upload, what the release names
# created: a new product or variant is often a typo, so say so loudly.
announced=0 release_id="" label=$AFFECTRA_PRODUCT
announce() {
	release_id=$(jq -r '.release.id' <<<"$body")
	[ "$announced" = 0 ] || return 0
	announced=1
	# The variant the server used: the one named, or the default.
	variant=$(jq -r '.variant.name // empty' <<<"$body")
	# The default variant is left out of names, as in the web app.
	case $variant in "" | default) ;; *) label+=" / $variant" ;; esac
	if [ "$(jq -r '.new.product' <<<"$body")" = true ]; then
		warning "created product \"$AFFECTRA_PRODUCT\" in Affectra; if that is a typo, delete it there and fix the workflow"
	fi
	# The default variant wasn't typed, so it can't be a typo.
	if [ "$(jq -r '.new.variant' <<<"$body")" = true ] && [ "$variant" != default ]; then
		warning "created variant \"$variant\" of \"$AFFECTRA_PRODUCT\" in Affectra"
	fi
	if [ "$(jq -r '.new.release' <<<"$body")" = true ]; then
		notice "created release $AFFECTRA_VERSION of $label"
	fi
}

# warnings prints the response's warnings as workflow warnings on file $1.
warnings() {
	local w
	while IFS= read -r w; do
		[ -z "$w" ] || warning "$w" "$1"
	done < <(jq -r '.warnings[]?' <<<"$body")
}

sbom_ids="" rows="" failed=0
for f in "${sbom_files[@]}"; do
	bundle=$(bundle_for "$f")
	if [ -n "$bundle" ]; then
		# multipart/form-data: the document and its signature. Copies under
		# fixed names, since curl -F reads ; and , in file names as options.
		cp "$f" "$tmp/sbom"
		[ "$bundle" = "$tmp/bundle.json" ] || cp "$bundle" "$tmp/bundle.json"
		body_args=(-F "sbom=@$tmp/sbom;type=application/octet-stream" -F "sigstore_bundle=@$tmp/bundle.json;type=application/json")
	else
		body_args=(-H "Content-Type: application/octet-stream" --data-binary "@$f")
	fi
	post "$f" "$org_base/sbom-uploads?$query" "${body_args[@]}" || {
		failed=1
		continue
	}
	case $code in
	200 | 201) ;;
	503)
		error "Affectra could not check the signature right now (503): $msg" "$f"
		failed=1
		continue
		;;
	*)
		error "upload failed ($code): $msg" "$f"
		failed=1
		continue
		;;
	esac

	announce
	sbom_id=$(jq -r '.sbom.id' <<<"$body")
	sbom_ids+="$sbom_id"$'\n'
	if [ "$(jq -r '.created' <<<"$body")" = true ]; then
		state="uploaded"
	else
		state="already there"
	fi
	components=$(jq -r '.sbom.components' <<<"$body")
	format=$(jq -r '.sbom.format + " " + .sbom.spec_version' <<<"$body")
	# verified: signed by a repository the organization trusts.
	signature=$(jq -r '.sbom.signature_status // "unsigned"' <<<"$body")
	echo "$f: $state ($format, $components components, $signature)"
	warnings "$f"
	rows+="| \`$f\` | $state | $format | $components | $signature |"$'\n'
done

# Build provenance goes to the same release, after the SBOMs (ADR 0024). Each
# file is a Sigstore bundle as actions/attest-build-provenance writes it
# (its bundle-path output), sent as it is.
attestation_ids="" provenance_rows=""
# ${a[@]+...}: bash 3 treats an empty array as unbound under set -u.
for f in ${provenance_files[@]+"${provenance_files[@]}"}; do
	post "$f" "$org_base/attestation-uploads?$query" -H "Content-Type: application/json" --data-binary "@$f" || {
		failed=1
		continue
	}
	case $code in
	200 | 201) ;;
	503)
		error "Affectra could not check the build provenance right now (503): $msg" "$f"
		failed=1
		continue
		;;
	*)
		error "provenance upload failed ($code): $msg" "$f"
		failed=1
		continue
		;;
	esac

	announce
	attestation_ids+="$(jq -r '.attestation.id' <<<"$body")"$'\n'
	if [ "$(jq -r '.created' <<<"$body")" = true ]; then
		state="uploaded"
	else
		state="already there"
	fi
	# verified: built by a repository the organization trusts.
	status=$(jq -r '.attestation.status' <<<"$body")
	images=$(jq -r '.attestation.subjects // [] | length' <<<"$body")
	echo "$f: $state (build provenance, $images images, $status)"
	warnings "$f"
	provenance_rows+="| \`$f\` | $state | $images | $status |"$'\n'
done

if [ -n "$release_id" ]; then
	release_url="$base/#/release/$release_id"
	output release-id "$release_id"
	output release-url "$release_url"
	output sbom-ids "${sbom_ids%$'\n'}"
	output attestation-ids "${attestation_ids%$'\n'}"
	summary "### Affectra: $label / $AFFECTRA_VERSION"
	if [ -n "$rows" ]; then
		summary ""
		summary "| File | Result | Format | Components | Signature |"
		summary "| --- | --- | --- | --- | --- |"
		summary "${rows%$'\n'}"
	fi
	if [ -n "$provenance_rows" ]; then
		summary ""
		summary "| Build provenance | Result | Images | Signature |"
		summary "| --- | --- | --- | --- |"
		summary "${provenance_rows%$'\n'}"
	fi
	summary ""
	summary "[Open the release in Affectra]($release_url). Vulnerabilities appear there once matching has run (usually within a minute)."
fi
exit "$failed"
