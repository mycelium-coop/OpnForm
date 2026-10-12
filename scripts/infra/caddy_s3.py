#!/usr/bin/env python3
"""Upload and download one R2 object with AWS Signature Version 4.

Uses path-style requests against R2_S3_ENDPOINT. Credentials come from
AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY. The script never prints them.
"""

import datetime
import hashlib
import hmac
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path


class S3Error(RuntimeError):
    def __init__(self, method, code, detail):
        super().__init__(f"R2 {method} failed with HTTP {code}: {detail}")
        self.method = method
        self.code = code


def _sign(key, message):
    return hmac.new(key, message.encode("utf-8"), hashlib.sha256).digest()


def _signing_key(secret, datestamp, region, service):
    key = _sign(("AWS4" + secret).encode("utf-8"), datestamp)
    key = _sign(key, region)
    key = _sign(key, service)
    return _sign(key, "aws4_request")


def _request(method, bucket, key, body, extra_headers=None):
    endpoint = os.environ["R2_S3_ENDPOINT"].rstrip("/")
    if "://" in endpoint:
        host = endpoint.split("://", 1)[1]
    else:
        host = endpoint
    access_key = os.environ["AWS_ACCESS_KEY_ID"]
    secret_key = os.environ["AWS_SECRET_ACCESS_KEY"]
    region = "auto"
    service = "s3"
    now = datetime.datetime.now(datetime.timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    datestamp = now.strftime("%Y%m%d")
    payload_hash = hashlib.sha256(body).hexdigest()
    canonical_uri = "/" + bucket.strip("/") + "/" + key.lstrip("/")
    headers = {
        "content-type": "application/octet-stream",
        "host": host,
        "x-amz-content-sha256": payload_hash,
        "x-amz-date": amz_date,
    }
    if extra_headers:
        headers.update({name.lower(): value for name, value in extra_headers.items()})
    canonical_headers = "".join(f"{name}:{headers[name]}\n" for name in sorted(headers))
    signed_headers = ";".join(sorted(headers))
    canonical_request = "\n".join(
        [
            method,
            canonical_uri,
            "",
            canonical_headers,
            signed_headers,
            payload_hash,
        ]
    )
    credential_scope = f"{datestamp}/{region}/{service}/aws4_request"
    string_to_sign = "\n".join(
        [
            "AWS4-HMAC-SHA256",
            amz_date,
            credential_scope,
            hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
        ]
    )
    signature = hmac.new(
        _signing_key(secret_key, datestamp, region, service),
        string_to_sign.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    authorization = (
        "AWS4-HMAC-SHA256 "
        f"Credential={access_key}/{credential_scope}, "
        f"SignedHeaders={signed_headers}, "
        f"Signature={signature}"
    )
    url = f"https://{host}{canonical_uri}"
    request = urllib.request.Request(url, data=body if method == "PUT" else None, method=method)
    for name, value in headers.items():
        request.add_header(name, value)
    request.add_header("Authorization", authorization)
    try:
        with urllib.request.urlopen(request, timeout=180) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        detail = error.read(500).decode("utf-8", errors="replace")
        raise S3Error(method, error.code, detail) from error


def _mirror_path(bucket, key):
    return Path(os.environ["CADDY_S3_MIRROR"]) / bucket / key


def _write_atomic(path, payload):
    temporary = path + ".partial"
    with open(temporary, "wb") as handle:
        handle.write(payload)
    os.replace(temporary, path)


def main():
    if len(sys.argv) != 5 or sys.argv[1] not in {"get", "put", "stat"}:
        raise SystemExit("Usage: caddy_s3.py <get|put|stat> <bucket> <key> <file>")
    action, bucket, key, path = sys.argv[1:]
    mirror = os.environ.get("CADDY_S3_MIRROR")
    if mirror:
        destination = _mirror_path(bucket, key)
        if action == "stat":
            print("present" if destination.is_file() else "absent")
            return
        if action == "put":
            if destination.exists():
                raise SystemExit(2)
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(Path(path).read_bytes())
            print("created")
            return
        if not destination.is_file():
            raise SystemExit("R2 GET failed with HTTP 404: mirror object is absent")
        _write_atomic(path, destination.read_bytes())
        return
    if action == "stat":
        try:
            _request("HEAD", bucket, key, b"")
        except S3Error as error:
            if error.code == 404:
                print("absent")
                return
            raise SystemExit(str(error)) from error
        print("present")
        return
    if action == "put":
        with open(path, "rb") as handle:
            payload = handle.read()
        try:
            _request("PUT", bucket, key, payload, {"If-None-Match": "*"})
        except S3Error as error:
            if error.code in {409, 412}:
                raise SystemExit(2) from error
            raise SystemExit(str(error)) from error
        print("created")
        return
    try:
        payload = _request("GET", bucket, key, b"")
    except S3Error as error:
        raise SystemExit(str(error)) from error
    _write_atomic(path, payload)


if __name__ == "__main__":
    main()
