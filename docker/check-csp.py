#!/usr/bin/env python3
"""Checks that the CSP Caddy sends allows every inline script the web build serves.

    docker/check-csp.py <webapp dir> <install.sh>

The CSP in the Caddyfile written by install.sh allows scripts from the site
itself plus the inline scripts it lists by sha256. Element itself has none, but
the bundled Element Call page does. When an upgrade changes them, calls would
stop working without any error outside the browser console, so the build fails
here instead and prints the hashes to put in install.sh.
"""
import base64
import hashlib
import pathlib
import re
import sys

# Pages users never open: decoder-ring is a developer tool for reading rageshakes.
IGNORED = {"decoder-ring/index.html"}

webapp, installer = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
allowed = set(re.findall(r"'(sha256-[A-Za-z0-9+/=]+)'", installer.read_text(encoding="utf-8")))

missing = {}
for page in sorted(webapp.rglob("*.html")):
    rel = page.relative_to(webapp).as_posix()
    if rel in IGNORED:
        continue
    html = page.read_text(encoding="utf-8")
    for body in re.findall(r"<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>", html, re.S):
        digest = "sha256-" + base64.b64encode(hashlib.sha256(body.encode()).digest()).decode()
        if digest not in allowed:
            missing.setdefault(rel, []).append(digest)

if missing:
    print("inline scripts not allowed by the CSP in deploy/install.sh:", file=sys.stderr)
    for rel, digests in missing.items():
        for digest in digests:
            print(f"  {rel}: '{digest}'", file=sys.stderr)
    sys.exit(1)
print(f"CSP allows every inline script ({len(allowed)} hash(es))")
