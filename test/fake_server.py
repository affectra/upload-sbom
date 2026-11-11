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


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        global count
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        item = script[min(count, len(script) - 1)]
        count += 1
        with open(countfile, "w") as f:
            f.write(str(count))
        with open(countfile + ".paths", "a") as f:
            f.write(f"{self.path.split('?')[0]} {self.headers.get('Content-Type', '').split(';')[0]}\n")
        status, _, retry = item.partition(":")
        self.send_response(int(status))
        if int(status) < 300:
            body = PROVENANCE if self.path.split("?")[0].endswith("/attestation-uploads") else OK
            ctype = "application/json"
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
