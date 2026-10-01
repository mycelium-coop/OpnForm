#!/usr/bin/env python3
"""Validate Cloudflare IP ranges and prepare origin-lock updates."""

from __future__ import annotations

import argparse
import ipaddress
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Iterable

API_URL = "https://api.cloudflare.com/client/v4/ips"
TEXT_V4_URL = "https://www.cloudflare.com/ips-v4"
TEXT_V6_URL = "https://www.cloudflare.com/ips-v6"
MAX_RANGES = 256
MIN_V4 = 10
MAX_V4 = 100
MIN_V6 = 5
MAX_V6 = 100


class RangeError(Exception):
    """Raised when Cloudflare IP range validation fails."""


def fetch(url: str) -> tuple[str, str | None]:
    request = urllib.request.Request(url, headers={"User-Agent": "opnform-cloudflare-ip-ranges/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            body = response.read().decode("utf-8")
            etag = response.headers.get("ETag")
            return body, etag
    except urllib.error.URLError as exc:
        raise RangeError(f"Failed to fetch {url}: {exc}") from exc


def parse_cidrs(lines: Iterable[str], family: int) -> list[str]:
    networks: list[ipaddress._BaseNetwork] = []
    seen: set[str] = set()
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        try:
            network = ipaddress.ip_network(line, strict=True)
        except ValueError as exc:
            raise RangeError(f"Invalid CIDR {line!r}: {exc}") from exc
        if network.version != family:
            raise RangeError(f"CIDR {line} is not IPv{family}")
        if not network.is_global:
            raise RangeError(f"CIDR {line} is not globally routable")
        rendered = str(network)
        if rendered in seen:
            raise RangeError(f"Duplicate CIDR {rendered}")
        seen.add(rendered)
        networks.append(network)

    for index, left in enumerate(networks):
        for right in networks[index + 1 :]:
            if left.overlaps(right):
                raise RangeError(f"Overlapping networks {left} and {right}")

    return [str(network) for network in networks]


def aggregate_address_count(cidrs: list[str]) -> int:
    total = 0
    for cidr in cidrs:
        network = ipaddress.ip_network(cidr, strict=True)
        total += network.num_addresses
    return total


def collapse(cidrs: Iterable[str]) -> list[str]:
    networks = [ipaddress.ip_network(cidr, strict=True) for cidr in cidrs]
    return [str(network) for network in ipaddress.collapse_addresses(networks)]


def read_cidr_file(path: Path, family: int, *, allow_missing: bool = False) -> list[str]:
    if not path.exists():
        if allow_missing:
            return []
        raise RangeError(f"Missing range file: {path}")
    text = path.read_text(encoding="utf-8")
    if not text.strip():
        raise RangeError(f"Empty range file: {path}")
    return parse_cidrs(text.splitlines(), family)


def write_cidr_file(path: Path, cidrs: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(cidrs) + ("\n" if cidrs else ""), encoding="utf-8")


def load_candidate() -> tuple[list[str], list[str], str]:
    api_body, api_etag_header = fetch(API_URL)
    text_v4, _ = fetch(TEXT_V4_URL)
    text_v6, _ = fetch(TEXT_V6_URL)

    try:
        payload = json.loads(api_body)
    except json.JSONDecodeError as exc:
        raise RangeError(f"Cloudflare API returned invalid JSON: {exc}") from exc

    if not payload.get("success"):
        raise RangeError("Cloudflare API response success!=true")

    result = payload.get("result") or {}
    api_v4 = parse_cidrs(result.get("ipv4_cidrs") or [], 4)
    api_v6 = parse_cidrs(result.get("ipv6_cidrs") or [], 6)
    text_v4_cidrs = parse_cidrs(text_v4.splitlines(), 4)
    text_v6_cidrs = parse_cidrs(text_v6.splitlines(), 6)

    if set(api_v4) != set(text_v4_cidrs):
        raise RangeError("Cloudflare API IPv4 ranges do not match ips-v4 text endpoint")
    if set(api_v6) != set(text_v6_cidrs):
        raise RangeError("Cloudflare API IPv6 ranges do not match ips-v6 text endpoint")

    if not (MIN_V4 <= len(api_v4) <= MAX_V4):
        raise RangeError(f"Unexpected IPv4 range count: {len(api_v4)}")
    if not (MIN_V6 <= len(api_v6) <= MAX_V6):
        raise RangeError(f"Unexpected IPv6 range count: {len(api_v6)}")

    etag = (payload.get("result", {}) or {}).get("etag") or api_etag_header
    if not isinstance(etag, str) or not etag.strip():
        # Cloudflare's /ips JSON historically omits etag in-body; fall back to header or hash.
        etag = api_etag_header or f"sha256:{hash((tuple(api_v4), tuple(api_v6))) & 0xFFFFFFFFFFFFFFFF:x}"
    etag = etag.strip().strip('"')
    if not etag:
        raise RangeError("Cloudflare IP response missing ETag")

    return api_v4, api_v6, etag


def cmd_prepare(args: argparse.Namespace) -> int:
    state_dir = Path(args.state_dir)
    active_v4 = read_cidr_file(state_dir / "active-v4.txt", 4, allow_missing=True)
    active_v6 = read_cidr_file(state_dir / "active-v6.txt", 6, allow_missing=True)
    candidate_v4, candidate_v6, etag = load_candidate()

    additions_v4 = sorted(set(candidate_v4) - set(active_v4))
    additions_v6 = sorted(set(candidate_v6) - set(active_v6))
    removals_v4 = sorted(set(active_v4) - set(candidate_v4))
    removals_v6 = sorted(set(active_v6) - set(candidate_v6))
    next_v4 = collapse(set(active_v4) | set(candidate_v4))
    next_v6 = collapse(set(active_v6) | set(candidate_v6))

    if len(next_v4) > MAX_RANGES or len(next_v6) > MAX_RANGES:
        raise RangeError("Prospective active set exceeds 256 ranges per family")

    if active_v4:
        active_count = aggregate_address_count(active_v4)
        next_count = aggregate_address_count(next_v4)
        if active_count > 0 and next_count > active_count * 2:
            raise RangeError("IPv4 aggregate address count grew by more than 2x")
    if active_v6:
        active_count = aggregate_address_count(active_v6)
        next_count = aggregate_address_count(next_v6)
        if active_count > 0 and next_count > active_count * 2:
            raise RangeError("IPv6 aggregate address count grew by more than 2x")

    write_cidr_file(state_dir / "candidate-v4.txt", candidate_v4)
    write_cidr_file(state_dir / "candidate-v6.txt", candidate_v6)
    write_cidr_file(state_dir / "pending-removals-v4.txt", removals_v4)
    write_cidr_file(state_dir / "pending-removals-v6.txt", removals_v6)
    (state_dir / "etag").write_text(etag + "\n", encoding="utf-8")

    summary = {
        "etag": etag,
        "additions_v4": additions_v4,
        "additions_v6": additions_v6,
        "removals_v4": removals_v4,
        "removals_v6": removals_v6,
        "next_v4": next_v4,
        "next_v6": next_v6,
        "active_v4_count": len(active_v4),
        "active_v6_count": len(active_v6),
        "candidate_v4_count": len(candidate_v4),
        "candidate_v6_count": len(candidate_v6),
    }
    (state_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    write_cidr_file(Path(args.next_v4), next_v4)
    write_cidr_file(Path(args.next_v6), next_v6)
    print(json.dumps(summary))
    return 0


def cmd_render_caddy(args: argparse.Namespace) -> int:
    v4 = read_cidr_file(Path(args.v4_file), 4)
    v6_path = Path(args.v6_file)
    if v6_path.exists() and v6_path.read_text(encoding="utf-8").strip():
        v6 = read_cidr_file(v6_path, 6)
    else:
        v6 = []
    ranges = v4 + v6
    if not ranges:
        raise RangeError("Refusing to render an empty Cloudflare remote_ip allowlist")

    body = f"""# Managed by opnform-cloudflare-ip-sync. Do not edit by hand.
@cloudflare remote_ip {' '.join(ranges)}
handle @cloudflare {{
\treverse_proxy 127.0.0.1:8080 {{
\t\theader_up X-Forwarded-For {{http.request.header.CF-Connecting-IP}}
\t\theader_up X-Real-IP {{http.request.header.CF-Connecting-IP}}
\t\theader_up X-Forwarded-Proto https
\t\theader_up X-Forwarded-Port 443
\t}}
}}
handle {{
\trespond "Origin access denied" 403
}}
"""
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(body, encoding="utf-8")
    return 0


def cmd_fetch_files(args: argparse.Namespace) -> int:
    v4, v6, etag = load_candidate()
    write_cidr_file(Path(args.v4_file), v4)
    write_cidr_file(Path(args.v6_file), v6)
    print(json.dumps({"etag": etag, "v4_count": len(v4), "v6_count": len(v6)}))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    prepare = sub.add_parser("prepare", help="Fetch, validate, and prepare the next active sets")
    prepare.add_argument("--state-dir", required=True)
    prepare.add_argument("--next-v4", required=True)
    prepare.add_argument("--next-v6", required=True)
    prepare.set_defaults(func=cmd_prepare)

    render = sub.add_parser("render-caddy", help="Render the Caddy Cloudflare gate snippet")
    render.add_argument("--v4-file", required=True)
    render.add_argument("--v6-file", required=True)
    render.add_argument("--output", required=True)
    render.set_defaults(func=cmd_render_caddy)

    fetch_files = sub.add_parser("fetch-files", help="Fetch validated ranges into files")
    fetch_files.add_argument("--v4-file", required=True)
    fetch_files.add_argument("--v6-file", required=True)
    fetch_files.set_defaults(func=cmd_fetch_files)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except RangeError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
