#!/usr/bin/env python3
"""Build and sign the update feed (latest.json) for the content updater.

  build       latest.json from the release zips (asset URL, size, SHA-256 per package)
  sign        RSA-SHA256 (PKCS#1 v1.5) signature of a file, base64 -> .sig
  verify      check a .sig against a private or public key
  pubkey-xml  print the public key as .NET <RSAKeyValue> XML (what update.ps1 embeds)
  fingerprint print the SHA-256 of the public key (DER), for the run summary

Key operations shell out to openssl so nothing beyond the standard library is needed.
The updater trusts latest.json only if its signature verifies, then trusts a zip only
if it matches the SHA-256 listed there, then trusts each file only if it matches the
install manifest inside that zip.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import re
import subprocess
import sys
import tempfile
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path


def openssl(*args: str, data: bytes | None = None) -> bytes:
    proc = subprocess.run(["openssl", *args], input=data, capture_output=True)
    if proc.returncode != 0:
        sys.exit(f"error: openssl {' '.join(args)} failed:\n{proc.stderr.decode(errors='replace')}")
    return proc.stdout


def public_pem(key: Path) -> bytes:
    text = key.read_text()
    if "PUBLIC KEY" in text and "PRIVATE" not in text:
        return text.encode()
    return openssl("pkey", "-in", str(key), "-pubout")


def b64_int(value: int) -> str:
    raw = value.to_bytes((value.bit_length() + 7) // 8, "big")
    return base64.b64encode(raw).decode()


def cmd_pubkey_xml(args: argparse.Namespace) -> int:
    text = openssl("rsa", "-pubin", "-noout", "-text", data=public_pem(args.key)).decode()
    # Modulus is printed as colon-separated hex over several lines
    m = re.search(r"Modulus:\s*\n((?:\s+[0-9a-f:]+\n)+)", text)
    e = re.search(r"Exponent:\s*(\d+)", text)
    if not m or not e:
        sys.exit("error: could not read modulus/exponent from the key")
    modulus = int(re.sub(r"[^0-9a-f]", "", m.group(1)), 16)
    if modulus.bit_length() < 2048:
        sys.exit("error: use an RSA key of at least 2048 bits (3072 recommended)")
    xml = f"<RSAKeyValue><Modulus>{b64_int(modulus)}</Modulus><Exponent>{b64_int(int(e.group(1)))}</Exponent></RSAKeyValue>"
    print(xml)
    return 0


def cmd_fingerprint(args: argparse.Namespace) -> int:
    der = openssl("pkey", "-pubin", "-outform", "DER", data=public_pem(args.key))
    print(hashlib.sha256(der).hexdigest())
    return 0


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def cmd_build(args: argparse.Namespace) -> int:
    zips = sorted(args.dist.glob("*.zip"))
    if not zips:
        sys.exit(f"error: no .zip files in {args.dist}")
    packages = {}
    for z in zips:
        packages[z.stem] = {
            "asset": z.name,
            "url": f"https://github.com/{args.repo}/releases/download/"
                   f"{urllib.parse.quote(args.tag)}/{urllib.parse.quote(z.name)}",
            "size": z.stat().st_size,
            "sha256": sha256_file(z),
        }
    feed = {
        "schema": 1,
        "repo": args.repo,
        "version": args.tag,
        "build": args.build,
        "published": args.published or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "notes_url": f"https://github.com/{args.repo}/releases/tag/{urllib.parse.quote(args.tag)}",
        "packages": packages,
    }
    args.out.write_text(json.dumps(feed, indent=2) + "\n", encoding="utf-8", newline="\n")
    print(args.out.read_text())
    return 0


def cmd_sign(args: argparse.Namespace) -> int:
    sig = openssl("dgst", "-sha256", "-sign", str(args.key), str(args.file))
    out = args.out or args.file.with_name(args.file.name + ".sig")
    out.write_text(base64.b64encode(sig).decode() + "\n", encoding="ascii", newline="\n")
    print(f"signed {args.file} -> {out}")
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    sig_path = args.sig or args.file.with_name(args.file.name + ".sig")
    sig = base64.b64decode(sig_path.read_text().strip())
    with tempfile.TemporaryDirectory() as tmp:
        pub = Path(tmp, "pub.pem")
        pub.write_bytes(public_pem(args.key))
        raw = Path(tmp, "sig.bin")
        raw.write_bytes(sig)
        proc = subprocess.run(
            ["openssl", "dgst", "-sha256", "-verify", str(pub), "-signature", str(raw), str(args.file)],
            capture_output=True,
        )
    if proc.returncode != 0:
        print(f"error: signature check failed for {args.file}", file=sys.stderr)
        return 1
    print(f"signature OK: {args.file}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("build")
    p.add_argument("--dist", required=True, type=Path)
    p.add_argument("--repo", required=True)
    p.add_argument("--tag", required=True)
    p.add_argument("--build", required=True, type=int)
    p.add_argument("--published")
    p.add_argument("--out", required=True, type=Path)
    p.set_defaults(func=cmd_build)

    p = sub.add_parser("sign")
    p.add_argument("--key", required=True, type=Path, help="private key (PEM)")
    p.add_argument("--file", required=True, type=Path)
    p.add_argument("--out", type=Path)
    p.set_defaults(func=cmd_sign)

    p = sub.add_parser("verify")
    p.add_argument("--key", required=True, type=Path, help="private or public key (PEM)")
    p.add_argument("--file", required=True, type=Path)
    p.add_argument("--sig", type=Path)
    p.set_defaults(func=cmd_verify)

    for name, func in (("pubkey-xml", cmd_pubkey_xml), ("fingerprint", cmd_fingerprint)):
        p = sub.add_parser(name)
        p.add_argument("--key", required=True, type=Path, help="private or public key (PEM)")
        p.set_defaults(func=func)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
