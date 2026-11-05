#!/usr/bin/env bash
# Uploads SBOM files to an Exposa release named by product, hardware
# revision and version (POST /v1/orgs/{org}/sbom-uploads, ADR 0005).
#
# Settings come from the environment (action.yml sets them):
#   EXPOSA_URL, EXPOSA_ORG, EXPOSA_PRODUCT, EXPOSA_HARDWARE_REVISION,
#   EXPOSA_VERSION, EXPOSA_SBOM (one path or glob per line),
#   EXPOSA_RELEASED_AT (optional), and for authentication either
#   EXPOSA_API_KEY or nothing: then the job's GitHub OIDC token is used
#   (needs `permissions: id-token: write`), with EXPOSA_AUDIENCE as its
#   audience (default: EXPOSA_URL).
# Needs bash, curl and jq; GitHub-hosted runners have all three.
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
	local delim="EXPOSA_$RANDOM$RANDOM$RANDOM"
	printf '%s<<%s\n%s\n%s\n' "$1" "$delim" "$2" "$delim" >>"$GITHUB_OUTPUT"
}
summary() { [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '%s\n' "$1" >>"$GITHUB_STEP_SUMMARY"; }

# --- check the settings ---

command -v curl >/dev/null || fail "curl is not installed on this runner"
command -v jq >/dev/null || fail "jq is not installed on this runner"

for v in EXPOSA_URL EXPOSA_ORG EXPOSA_PRODUCT EXPOSA_HARDWARE_REVISION EXPOSA_VERSION EXPOSA_SBOM; do
	[ -n "$(printf '%s' "${!v:-}" | tr -d '[:space:]')" ] || fail "input ${v#EXPOSA_} is empty"
done

base=${EXPOSA_URL%/}
case $base in
https://*) ;;
http://localhost | http://localhost:* | http://127.0.0.1 | http://127.0.0.1:* | http://\[::1\]*) ;;
*) fail "url must start with https:// (plain http only for localhost): $base" ;;
esac

uri() { jq -rn --arg v "$1" '$v | @uri'; }

# --- authentication: an API key, or the job's GitHub OIDC token ---

key=$(printf '%s' "${EXPOSA_API_KEY:-}" | tr -d '[:space:]')
if [ -n "$key" ]; then
	auth=key
	# Secrets are masked already; this also covers a key passed another way.
	echo "::add-mask::$key"
	case $key in
	*[!A-Za-z0-9_-]*) fail "the API key has unexpected characters; pass the key exactly as Exposa showed it" ;;
	esac
elif [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
	auth=oidc
	audience=${EXPOSA_AUDIENCE:-$base}
else
	fail "no credentials: give the job \"permissions: id-token: write\" (and trust this repository in Exposa under Trusted publishers), or pass api-key"
fi
query="product=$(uri "$EXPOSA_PRODUCT")&hardware_revision=$(uri "$EXPOSA_HARDWARE_REVISION")&version=$(uri "$EXPOSA_VERSION")"
[ -z "$EXPOSA_RELEASED_AT" ] || query+="&released_at=$(uri "$EXPOSA_RELEASED_AT")"
endpoint="$base/v1/orgs/$(uri "$EXPOSA_ORG")/sbom-uploads?$query"

# --- expand the file list ---

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
		[ -f "$f" ] || fail "not a file: $f"
		files+=("$f")
	done
done <<<"$EXPOSA_SBOM"
shopt -u nullglob
[ ${#files[@]} -gt 0 ] || fail "no SBOM files given"

# --- upload ---

tmp=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/exposa.XXXXXX")
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

release_id="" sbom_ids="" rows="" failed=0 announced=0
for f in "${files[@]}"; do
	authorize
	code=$(curl --silent --show-error --config "$tmp/auth" \
		--retry 4 --retry-connrefused --connect-timeout 20 --max-time 600 \
		-H "Content-Type: application/octet-stream" \
		--data-binary "@$f" -o "$tmp/response" -w '%{http_code}' \
		"$endpoint") || {
		error "could not reach Exposa at $base" "$f"
		failed=1
		continue
	}
	body=$(cat "$tmp/response")
	case $code in
	200 | 201) ;;
	401)
		[ "$auth" = key ] && fail "Exposa rejected the API key (401). Is it revoked, or from another Exposa instance?"
		fail "Exposa rejected the GitHub OIDC token (401). Does this Exposa instance accept GitHub Actions tokens for audience \"$audience\"?"
		;;
	404)
		[ "$auth" = key ] && fail "organization \"$EXPOSA_ORG\" not found for this API key (404). The key must belong to that organization."
		fail "organization \"$EXPOSA_ORG\" does not trust $repo for this run (404). An admin adds it in Exposa under Trusted publishers; check its workflow, ref and environment restrictions (this run: ${GITHUB_WORKFLOW_REF:-unknown workflow})."
		;;
	403) fail "not allowed to upload (403): $body" ;;
	*)
		error "upload failed ($code): $body" "$f"
		failed=1
		continue
		;;
	esac

	release_id=$(jq -r '.release.id' <<<"$body")
	sbom_id=$(jq -r '.sbom.id' <<<"$body")
	sbom_ids+="$sbom_id"$'\n'

	if [ "$announced" = 0 ]; then
		announced=1
		# A new product or revision is often a typo; say so loudly.
		if [ "$(jq -r '.new.product' <<<"$body")" = true ]; then
			warning "created product \"$EXPOSA_PRODUCT\" in Exposa; if that is a typo, delete it there and fix the workflow"
		fi
		if [ "$(jq -r '.new.hardware_revision' <<<"$body")" = true ]; then
			warning "created hardware revision \"$EXPOSA_HARDWARE_REVISION\" of \"$EXPOSA_PRODUCT\" in Exposa"
		fi
		if [ "$(jq -r '.new.release' <<<"$body")" = true ]; then
			notice "created release $EXPOSA_VERSION of $EXPOSA_PRODUCT / $EXPOSA_HARDWARE_REVISION"
		fi
	fi

	if [ "$(jq -r '.created' <<<"$body")" = true ]; then
		state="uploaded"
	else
		state="already there"
	fi
	components=$(jq -r '.sbom.components' <<<"$body")
	format=$(jq -r '.sbom.format + " " + .sbom.spec_version' <<<"$body")
	echo "$f: $state ($format, $components components)"
	while IFS= read -r w; do
		[ -z "$w" ] || warning "$w" "$f"
	done < <(jq -r '.warnings[]?' <<<"$body")
	rows+="| \`$f\` | $state | $format | $components |"$'\n'
done

if [ -n "$release_id" ]; then
	release_url="$base/#/releases/$release_id"
	output release-id "$release_id"
	output release-url "$release_url"
	output sbom-ids "${sbom_ids%$'\n'}"
	summary "### Exposa: $EXPOSA_PRODUCT / $EXPOSA_HARDWARE_REVISION / $EXPOSA_VERSION"
	summary ""
	summary "| File | Result | Format | Components |"
	summary "| --- | --- | --- | --- |"
	summary "${rows%$'\n'}"
	summary ""
	summary "[Open the release in Exposa]($release_url). Vulnerabilities appear there once matching has run (usually within a minute)."
fi
exit "$failed"
