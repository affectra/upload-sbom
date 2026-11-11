#!/usr/bin/env bash
# Runs upload.sh against a fake Affectra (test/fake_server.py) to check the
# retry handling. Needs bash, curl, jq and python3. A fake `sleep` on PATH
# records the waits instead of sleeping. Usage: test/run.sh
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
srv_pid=""
cleanup() {
	[ -z "$srv_pid" ] || kill "$srv_pid" 2>/dev/null || true
	rm -rf "$work"
}
trap cleanup EXIT

mkdir "$work/bin"
cat >"$work/bin/sleep" <<'SH'
#!/bin/sh
echo "$1" >>"$SLEEP_LOG"
SH
chmod +x "$work/bin/sleep"
echo '{"bomFormat":"CycloneDX","specVersion":"1.5","components":[]}' >"$work/sbom.json"
echo '{"mediaType":"application/vnd.dev.sigstore.bundle.v0.3+json"}' >"$work/fw.provenance.sigstore.json"
# provenance is the provenance input of the next checks; empty: SBOMs only.
provenance=""

failures=0
# check NAME EXIT REQUESTS SLEEPS OUTPUT_PATTERN SCRIPT...
# SCRIPT items: STATUS or STATUS:RETRY_AFTER, one per request (the last repeats).
check() {
	local name=$1 want_exit=$2 want_reqs=$3 want_sleeps=$4 pattern=$5
	shift 5
	rm -f "$work/port" "$work/count" "$work/count.paths" "$work/sleeps" "$work/out" "$work/ghout"
	python3 "$root/test/fake_server.py" "$work/port" "$work/count" "$@" &
	srv_pid=$!
	while [ ! -s "$work/port" ]; do command sleep 0.05; done
	local exit_code=0
	(
		cd "$work"
		PATH="$work/bin:$PATH" SLEEP_LOG="$work/sleeps" RUNNER_TEMP="$work" \
			AFFECTRA_URL="http://127.0.0.1:$(cat "$work/port")" AFFECTRA_ORG=acme \
			AFFECTRA_PRODUCT=p AFFECTRA_VERSION=1 AFFECTRA_SBOM=sbom.json \
			AFFECTRA_RELEASED_AT="" AFFECTRA_API_KEY=testkey AFFECTRA_PROVENANCE="$provenance" \
			GITHUB_OUTPUT="$work/ghout" \
			bash "$root/upload.sh"
	) >"$work/out" 2>&1 || exit_code=$?
	kill "$srv_pid" 2>/dev/null || true
	wait "$srv_pid" 2>/dev/null || true
	srv_pid=""
	local reqs sleeps
	reqs=0
	[ ! -f "$work/count" ] || reqs=$(cat "$work/count")
	sleeps=""
	[ ! -f "$work/sleeps" ] || sleeps=$(tr '\n' ' ' <"$work/sleeps")
	sleeps=${sleeps% }
	if [ "$exit_code" = "$want_exit" ] && [ "$reqs" = "$want_reqs" ] && [ "$sleeps" = "$want_sleeps" ] &&
		grep -qF -- "$pattern" "$work/out"; then
		echo "ok   $name"
	else
		echo "FAIL $name: exit $exit_code (want $want_exit), requests $reqs (want $want_reqs), sleeps '$sleeps' (want '$want_sleeps'), output must contain '$pattern'"
		sed 's/^/     /' "$work/out"
		failures=$((failures + 1))
	fi
}

check "429 then 201: one retry" 0 2 "7" "uploaded" 429:7 201
check "429 twice: fails with the problem message" 1 2 "3" "upload failed (429): Too many requests [request.rateLimited]" 429:3
check "429 without Retry-After: default 30s" 0 2 "30" "uploaded" 429 201
check "429 with an HTTP date: default 30s" 0 2 "30" "uploaded" "429:Wed, 21 Oct 2037 07:28:00 GMT" 201
check "Retry-After over the cap: no wait, no retry" 1 1 "" "Too many requests [request.rateLimited]" 429:301
check "Retry-After huge: no wait, no retry" 1 1 "" "not retrying" 429:99999999999999999999
check "Retry-After at the cap: waits" 0 2 "300" "uploaded" 429:300 201
check "other 4xx: no retry" 1 1 "" "upload failed (400)" 400
check "503 is retried with backoff" 0 3 "1 2" "uploaded" 503 503 201

# Build provenance goes after the SBOM, as raw JSON, to attestation-uploads.
provenance="fw.provenance.sigstore.json"
check "provenance after the SBOM" 0 2 "" "fw.provenance.sigstore.json: uploaded (build provenance, 1 images, verified)" 201
want="/v1/orgs/acme/sbom-uploads application/octet-stream
/v1/orgs/acme/attestation-uploads application/json"
if [ "$(cat "$work/count.paths")" = "$want" ] 2>/dev/null; then
	echo "ok   provenance requests: route and Content-Type"
else
	echo "FAIL provenance requests: got"
	sed 's/^/     /' "$work/count.paths"
	failures=$((failures + 1))
fi
if grep -qx "a1" "$work/ghout"; then
	echo "ok   provenance: attestation-ids output"
else
	echo "FAIL provenance: attestation-ids output missing"
	failures=$((failures + 1))
fi
check "provenance refused: fails with the problem message" 1 2 "" "provenance upload failed (400)" 201 400
check "provenance 429 then 201: one retry" 0 3 "5" "(build provenance, 1 images, verified)" 201 429:5 201
check "provenance 404 after the SBOM: an older Affectra" 1 2 "" "does not accept build provenance yet" 201 404
provenance="missing/*.json"
check "provenance glob with no match fails before uploading" 1 0 "" "no file matches: missing/*.json" 201
provenance=""

[ "$failures" = 0 ] || exit 1
