"""Fake Affectra for test/run.sh: answers each POST with the next scripted
response and records the request count, and each request's path and
Content-Type in COUNTFILE.paths. Usage:
fake_server.py PORTFILE COUNTFILE SCRIPT...
Each SCRIPT item is STATUS or STATUS:RETRY_AFTER; the last one repeats."""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

portfile, countfile, *script = sys.argv[1:]
count = 0

OK = {
    "release": {"id": "r1"},
    "variant": {"name": "default"},
    "sbom": {"id": "s1", "components": 1, "format": "CycloneDX", "spec_version": "1.5"},
    "new": {},
    "created": True,
}

# What attestation-uploads answers: one image, built by a trusted publisher.
PROVENANCE = {
    "release": {"id": "r1"},
    "variant": {"name": "default"},
    "attestation": {
        "id": "a1",
        "status": "verified",
        "subjects": [{"name": "fw.bin", "digest": {"sha256": "ab", "sha512": "cd"}}],
    },
    "new": {},
    "created": True,
    "warnings": [],
}

# What attestation-uploads answers for a model signature (a body naming
# model_signing): two files of one model, signed by a trusted publisher.
MODEL_SIGNATURE = {
    "release": {"id": "r1"},
    "variant": {"name": "default"},
    "attestation": {
        "id": "m1",
        "kind": "model_signature",
        "model_name": "person-detect",
        "status": "verified",
        "subjects": [
            {"name": "model.tflite", "digest": {"sha256": "ab"}},
            {"name": "config.json", "digest": {"sha256": "cd"}},
        ],
    },
    "new": {},
    "created": True,
    "warnings": [],
}

# What build-config-uploads answers: an ESP-IDF sdkconfig for an ESP32.
BUILD_CONFIG = {
    "release": {"id": "r1"},
    "variant": {"name": "default"},
    "build_config": {
        "id": "b1",
        "build_system": "esp-idf",
        "cpu_arch": "xtensa",
        "target": "esp32",
        "symbol_count": 412,
    },
    "new": {},
    "created": True,
}

# The problem code of an error answer: what Affectra sends for that status
# on these routes.
CODES = {403: "buildConfig.signatureRequired", 400: "buildConfig.invalid"}


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        global count
        request = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        item = script[min(count, len(script) - 1)]
        count += 1
        with open(countfile, "w") as f:
            f.write(str(count))
        with open(countfile + ".paths", "a") as f:
            f.write(f"{self.path.split('?')[0]} {self.headers.get('Content-Type', '').split(';')[0]}\n")
        status, _, retry = item.partition(":")
        self.send_response(int(status))
        path = self.path.split("?")[0]
        if int(status) < 300:
            if path.endswith("/attestation-uploads"):
                body = MODEL_SIGNATURE if b"model_signing" in request else PROVENANCE
            elif path.endswith("/build-config-uploads"):
                body = BUILD_CONFIG
            else:
                body = OK
            ctype = "application/json"
        elif int(status) in CODES and path.endswith("/build-config-uploads"):
            body = {"code": CODES[int(status)], "detail": "Refused"}
            ctype = "application/problem+json"
        else:
            body = {"code": "request.rateLimited", "detail": "Too many requests"}
            ctype = "application/problem+json"
        if retry:
            self.send_header("Retry-After", retry)
        self.send_header("Content-Type", ctype)
        data = json.dumps(body).encode()
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


srv = HTTPServer(("127.0.0.1", 0), H)
with open(portfile, "w") as f:
    f.write(str(srv.server_port))
srv.serve_forever()
