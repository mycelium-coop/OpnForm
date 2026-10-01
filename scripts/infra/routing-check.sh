#!/usr/bin/env bash

set -euo pipefail

# Isolated routing harness for the upstream-Nginx + Caddy rewrite architecture.
# Uses synthetic backends, production templates, and docker/nginx.conf.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

root="$(infra_root)"
require_command docker
require_command python3
require_command curl
require_command sha256sum

mkdir -p "${root}/infra/.tmp"
workdir="$(mktemp -d "${root}/infra/.tmp/routing-check.XXXXXX")"
network_name="opnform-routing-check-$$"
caddy_name="opnform-routing-caddy-$$"
nginx_name="opnform-routing-nginx-$$"
api_name="opnform-routing-api-$$"
ui_name="opnform-routing-ui-$$"
external_port="${ROUTING_CHECK_EXTERNAL_PORT:-18443}"
hostname="routing-check.example.test"

cleanup() {
  docker rm -f "${caddy_name}" "${nginx_name}" "${api_name}" "${ui_name}" >/dev/null 2>&1 || true
  docker network rm "${network_name}" >/dev/null 2>&1 || true
  rm -rf "${workdir}"
}
trap cleanup EXIT

printf '%s\n' "Working directory: ${workdir}"

bash "${root}/scripts/infra/check-nuxt-icon-endpoint.sh"

upstream_nginx="${root}/docker/nginx.conf"
[[ -f "${upstream_nginx}" ]] || {
  printf '%s\n' "Missing ${upstream_nginx}" >&2
  exit 1
}

cp "${upstream_nginx}" "${workdir}/nginx.conf"
template_sum="$(sha256sum "${upstream_nginx}" | awk '{print $1}')"
mounted_sum="$(sha256sum "${workdir}/nginx.conf" | awk '{print $1}')"
[[ "${template_sum}" == "${mounted_sum}" ]] || {
  printf '%s\n' "Mounted Nginx template checksum mismatch." >&2
  exit 1
}
printf '%s\n' "Nginx template checksum matches docker/nginx.conf."

python3 - "${root}" "${workdir}" "${hostname}" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
workdir = pathlib.Path(sys.argv[2])
hostname = sys.argv[3]

site = (root / "infra/ansible/roles/caddy/templates/opnform.caddy.j2").read_text(encoding="utf-8")
site = site.replace("{{ opnform_hostname }}", hostname)
site = site.replace("{{ opnform_caddy_email }}", "routing-check@example.test")
site = site.replace("{{ opnform_maintenance_file }}", str(workdir / "maintenance.caddy"))
site = site.replace("{{ opnform_cloudflare_gate_snippet }}", str(workdir / "gate.caddy"))

lines = []
skip_depth = 0
for line in site.splitlines():
    if skip_depth:
        skip_depth += line.count("{") - line.count("}")
        continue
    if line.strip().startswith("tls {"):
        skip_depth = line.count("{") - line.count("}")
        continue
    # Drop encode for the HTTP fixture; keep rewrite/route behavior.
    if line.strip().startswith("encode "):
        continue
    lines.append(line)
site = "\n".join(lines) + "\n"
site = re.sub(
    r"\{% if opnform_cloudflare_proxied \| bool and opnform_caddy_origin_lockdown \| bool %\}.*?\{% else %\}",
    "",
    site,
    flags=re.S,
)
site = site.replace("{% endif %}", "")
site = site.replace("127.0.0.1:8080", "nginx:80")
site = site.replace("header_up X-Forwarded-Port 443", "header_up X-Forwarded-Port 8080")
site = site.replace(f"{hostname} {{", ":80 {", 1)
(workdir / "site.caddy").write_text(site, encoding="utf-8")
(workdir / "Caddyfile").write_text(
    "{\n    auto_https off\n    admin off\n}\nimport "
    + str(workdir / "site.caddy")
    + "\n",
    encoding="utf-8",
)

(workdir / "maintenance.on.caddy").write_text(
    'handle {\n    header Retry-After "120"\n'
    '    respond "OpnForm is temporarily undergoing maintenance." 503\n}\n',
    encoding="utf-8",
)
(workdir / "maintenance.off.caddy").write_text("# maintenance disabled\n", encoding="utf-8")
(workdir / "maintenance.caddy").write_text("# maintenance disabled\n", encoding="utf-8")

(workdir / "gate.caddy").write_text(
    "# harness gate\n"
    "@cloudflare remote_ip 173.245.48.0/20\n"
    "handle @cloudflare {\n"
    "\treverse_proxy nginx:80 {\n"
    "\t\theader_up X-Forwarded-For {http.request.header.CF-Connecting-IP}\n"
    "\t\theader_up X-Real-IP {http.request.header.CF-Connecting-IP}\n"
    "\t\theader_up X-Forwarded-Proto https\n"
    "\t\theader_up X-Forwarded-Port 443\n"
    "\t}\n"
    "}\n"
    "handle {\n"
    '\trespond "Origin access denied" 403\n'
    "}\n",
    encoding="utf-8",
)
(workdir / "lockdown.site.caddy").write_text(
    ":80 {\n"
    "    @opnform_version path /v\n"
    "    rewrite @opnform_version /api/v\n"
    "    @legacy_nuxt_icon path /api/_nuxt_icon /api/_nuxt_icon/*\n"
    "    uri @legacy_nuxt_icon strip_prefix /api\n"
    "    route {\n"
    f"        import {workdir / 'maintenance.caddy'}\n"
    f"        import {workdir / 'gate.caddy'}\n"
    "    }\n"
    "}\n",
    encoding="utf-8",
)

api = workdir / "api"
ui = workdir / "ui"
api.mkdir()
ui.mkdir()
(ui / "_nuxt_icon").mkdir()
(api / "index.php").write_text(
    "<?php\n"
    "$uri = $_SERVER['REQUEST_URI'] ?? '';\n"
    "if (str_starts_with($uri, '/healthcheck')) {\n"
    "  header('Content-Type: application/json');\n"
    "  echo json_encode(['success' => true]);\n"
    "  exit;\n"
    "}\n"
    "if (str_starts_with($uri, '/v')) {\n"
    "  header('Content-Type: text/plain');\n"
    "  echo \"v-test\\nsha-routingcheck\\n\";\n"
    "  exit;\n"
    "}\n"
    "header('Content-Type: text/plain');\n"
    "echo 'api:'.$uri.\"\\n\";\n"
    "echo 'xff:'.($_SERVER['HTTP_X_FORWARDED_FOR'] ?? '').\"\\n\";\n"
    "echo 'xfp:'.($_SERVER['HTTP_X_FORWARDED_PORT'] ?? '').\"\\n\";\n"
    "echo 'xfc:'.($_SERVER['HTTP_CF_CONNECTING_IP'] ?? '').\"\\n\";\n",
    encoding="utf-8",
)
(ui / "login").write_text("ui-login\n", encoding="utf-8")
(ui / "_nuxt_icon" / "heroicons.json").write_text(
    '{"prefix":"heroicons","icons":{"chevron-up-down-16-solid":{"body":"<path d=\\"M1\\"/>"}}}',
    encoding="utf-8",
)
(ui / "_nuxt_icon" / "material-symbols.json").write_text(
    '{"prefix":"material-symbols","icons":{"check-box-outline-blank":{"body":"<path d=\\"M2\\"/>"}}}',
    encoding="utf-8",
)
print("Rendered Caddy fixtures.")
PY

python3 "${root}/scripts/cloudflare-ip-ranges.py" render-caddy \
  --v4-file <(printf '173.245.48.0/20\n') \
  --v6-file <(printf '\n') \
  --output "${workdir}/rendered-gate.caddy"
grep -Fq 'header_up X-Forwarded-Port 443' "${workdir}/rendered-gate.caddy"
grep -Fq 'CF-Connecting-IP' "${workdir}/rendered-gate.caddy"
printf '%s\n' "Cloudflare gate renderer sets port 443 and CF-Connecting-IP."

python3 - "${root}" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1], "infra/ansible/roles/opnform/templates/docker-compose.yml.j2").read_text(encoding="utf-8")
assert "opnform-client" in text and "opnform-api" in text
assert "NGINX_MAX_BODY_SIZE: 64m" in text
worker = text.split("api-worker:", 1)[1].split("api-scheduler:", 1)[0]
sched = text.split("api-scheduler:", 1)[1].split("ui:", 1)[0]
assert "aliases:" not in worker and "aliases:" not in sched
assert "nginx.conf:/etc/nginx/templates/default.conf.template" in text
print("Compose template aliases and Nginx mount look correct.")
PY

cat >"${workdir}/nginx.harness.conf" <<'EOF'
server {
    listen 80;
    server_name opnform;
    client_max_body_size 64m;
    resolver 127.0.0.11 valid=10s ipv6=off;

    location / {
        proxy_http_version 1.1;
        proxy_pass http://opnform-client:3000;
    }

    location /api/ {
        rewrite ^/api/(.*)$ /$1 break;
        proxy_http_version 1.1;
        proxy_pass http://opnform-api:9000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host $http_x_forwarded_host;
        proxy_set_header X-Forwarded-Port $http_x_forwarded_port;
        proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;
    }
}
EOF

docker network create "${network_name}" >/dev/null

docker run -d --name "${api_name}" --network "${network_name}" --network-alias opnform-api \
  -v "${workdir}/api:/app:ro" -w /app php:8.3-cli \
  php -S 0.0.0.0:9000 -t /app >/dev/null

docker run -d --name "${ui_name}" --network "${network_name}" --network-alias opnform-client \
  -v "${workdir}/ui:/usr/share/nginx/html:ro" \
  nginx:1.27-alpine \
  /bin/sh -c 'printf "server{listen 3000;root /usr/share/nginx/html;location /{try_files \$uri \$uri/ =404;}}\n" >/etc/nginx/conf.d/default.conf && nginx -g "daemon off;"' \
  >/dev/null

# Wait for stub backends before validating/starting ingress.
for _ in $(seq 1 30); do
  if docker exec "${ui_name}" wget -qO- http://127.0.0.1:3000/login >/dev/null 2>&1 \
    && docker exec "${api_name}" php -r 'exit(@file_get_contents("http://127.0.0.1:9000/healthcheck") ? 0 : 1);' >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

docker run --rm --network "${network_name}" \
  -e NGINX_MAX_BODY_SIZE=64m \
  -v "${workdir}/nginx.conf:/etc/nginx/templates/default.conf.template:ro" \
  nginx:1.27-alpine \
  /bin/sh -c '/docker-entrypoint.d/20-envsubst-on-templates.sh >/dev/null && nginx -t && grep -Fq "client_max_body_size 64m;" /etc/nginx/conf.d/default.conf' \
  >/dev/null
printf '%s\n' "Upstream Nginx template validates with NGINX_MAX_BODY_SIZE=64m."

docker run -d --name "${nginx_name}" --network "${network_name}" --network-alias nginx \
  -v "${workdir}/nginx.harness.conf:/etc/nginx/conf.d/default.conf:ro" \
  nginx:1.27-alpine >/dev/null

for _ in $(seq 1 30); do
  if docker exec "${nginx_name}" wget -qO- http://opnform-client:3000/login >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

# Point Caddy imports at paths inside the container mount.
python3 - "${workdir}" <<'PY'
from pathlib import Path
import sys
workdir = Path(sys.argv[1])
for name in ("site.caddy", "lockdown.site.caddy", "Caddyfile", "Caddyfile.lockdown"):
    path = workdir / name
    if not path.exists():
        continue
    text = path.read_text(encoding="utf-8")
    text = text.replace(str(workdir), "/fixture")
    path.write_text(text, encoding="utf-8")
PY

# Rewrite site imports after the unlocked Caddyfile was written.
python3 - "${workdir}" <<'PY'
from pathlib import Path
import sys
workdir = Path(sys.argv[1])
site = (workdir / "site.caddy").read_text(encoding="utf-8")
site = site.replace(str(workdir), "/fixture")
(workdir / "site.caddy").write_text(site, encoding="utf-8")
(workdir / "Caddyfile").write_text(
    "{\n    auto_https off\n    admin off\n}\nimport /fixture/site.caddy\n",
    encoding="utf-8",
)
lock = (workdir / "lockdown.site.caddy").read_text(encoding="utf-8")
lock = lock.replace(str(workdir), "/fixture")
(workdir / "lockdown.site.caddy").write_text(lock, encoding="utf-8")
(workdir / "Caddyfile.lockdown").write_text(
    "{\n    auto_https off\n    admin off\n}\nimport /fixture/lockdown.site.caddy\n",
    encoding="utf-8",
)
PY

docker run --rm -v "${workdir}:/fixture:ro" caddy:2.10-alpine \
  caddy validate --config /fixture/Caddyfile --adapter caddyfile >/dev/null

docker run -d --name "${caddy_name}" --network "${network_name}" \
  -v "${workdir}:/fixture" \
  -p "127.0.0.1:${external_port}:80" \
  caddy:2.10-alpine \
  caddy run --config /fixture/Caddyfile --adapter caddyfile >/dev/null

for _ in $(seq 1 40); do
  if curl -fsS "http://127.0.0.1:${external_port}/login" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

assert_contains() {
  local body="$1"
  local needle="$2"
  local label="$3"
  printf '%s' "${body}" | grep -Fq "${needle}" || {
    printf '%s\n' "Assertion failed (${label}): missing '${needle}' in: ${body}" >&2
    exit 1
  }
}

health="$(curl -fsS "http://127.0.0.1:${external_port}/api/healthcheck")"
assert_contains "${health}" '"success":true' "health via caddy+nginx"

version="$(curl -fsS "http://127.0.0.1:${external_port}/v")"
assert_contains "${version}" 'sha-routingcheck' "public /v rewrite"
[[ "$(printf '%s\n' "${version}" | sed '/^$/d' | wc -l | tr -d ' ')" == "2" ]]

version_qs="$(curl -fsS "http://127.0.0.1:${external_port}/v?x=1")"
assert_contains "${version_qs}" 'sha-routingcheck' "/v query survival"

icon="$(curl -fsS "http://127.0.0.1:${external_port}/_nuxt_icon/heroicons.json?icons=chevron-up-down-16-solid")"
assert_contains "${icon}" '"prefix":"heroicons"' "new icon path"
assert_contains "${icon}" 'M1' "icon svg body"

material="$(curl -fsS "http://127.0.0.1:${external_port}/_nuxt_icon/material-symbols.json?icons=check-box-outline-blank")"
assert_contains "${material}" '"prefix":"material-symbols"' "material symbols path"
assert_contains "${material}" 'M2' "material svg body"

legacy="$(curl -fsS "http://127.0.0.1:${external_port}/api/_nuxt_icon/heroicons.json?icons=chevron-up-down-16-solid")"
assert_contains "${legacy}" '"prefix":"heroicons"' "legacy icon rewrite"
[[ "${icon}" == "${legacy}" ]]

headers="$(curl -sSI "http://127.0.0.1:${external_port}/api/_nuxt_icon/heroicons.json?icons=chevron-up-down-16-solid")"
printf '%s' "${headers}" | grep -Ei '^HTTP/' | head -n1 | grep -Eq '200'
if printf '%s' "${headers}" | grep -Eiq '^location:'; then
  printf '%s\n' "Legacy icon path redirected unexpectedly." >&2
  exit 1
fi

login="$(curl -fsS "http://127.0.0.1:${external_port}/login")"
assert_contains "${login}" 'ui-login' "nuxt login"

api_echo="$(curl -fsS -H 'X-Forwarded-Port: 9999' -H 'CF-Connecting-IP: 198.51.100.50' \
  "http://127.0.0.1:${external_port}/api/echo-headers")"
assert_contains "${api_echo}" 'xfp:8080' "forced harness external port"
# Non-lockdown Caddy must not promote CF-Connecting-IP into X-Forwarded-For.
if printf '%s' "${api_echo}" | grep -E '^xff:.*198\.51\.100\.50' >/dev/null; then
  printf '%s\n' "Non-lockdown path promoted forged CF-Connecting-IP into X-Forwarded-For." >&2
  printf '%s\n' "${api_echo}" >&2
  exit 1
fi

cp "${workdir}/maintenance.on.caddy" "${workdir}/maintenance.caddy"

docker rm -f "${caddy_name}" >/dev/null
docker run -d --name "${caddy_name}" --network "${network_name}" \
  -v "${workdir}:/fixture" \
  -p "127.0.0.1:${external_port}:80" \
  caddy:2.10-alpine \
  caddy run --config /fixture/Caddyfile.lockdown --adapter caddyfile >/dev/null

for _ in $(seq 1 40); do
  code="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${external_port}/v" || true)"
  if [[ "${code}" == "503" ]]; then
    break
  fi
  sleep 0.5
done

maint_code="$(curl -sS -o "${workdir}/maint.body" -w '%{http_code}' "http://127.0.0.1:${external_port}/v")"
[[ "${maint_code}" == "503" ]] || {
  printf '%s\n' "Expected maintenance 503, got ${maint_code}" >&2
  docker logs "${caddy_name}" >&2 || true
  exit 1
}
assert_contains "$(cat "${workdir}/maint.body")" 'undergoing maintenance' "maintenance body"

maint_icon="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${external_port}/_nuxt_icon/heroicons.json?icons=chevron-up-down-16-solid")"
[[ "${maint_icon}" == "503" ]]

legacy_maint="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${external_port}/api/_nuxt_icon/heroicons.json?icons=chevron-up-down-16-solid")"
[[ "${legacy_maint}" == "503" ]]

cp "${workdir}/maintenance.off.caddy" "${workdir}/maintenance.caddy"
docker rm -f "${caddy_name}" >/dev/null
docker run -d --name "${caddy_name}" --network "${network_name}" \
  -v "${workdir}:/fixture" \
  -p "127.0.0.1:${external_port}:80" \
  caddy:2.10-alpine \
  caddy run --config /fixture/Caddyfile.lockdown --adapter caddyfile >/dev/null

for _ in $(seq 1 40); do
  code="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${external_port}/v" || true)"
  if [[ "${code}" == "403" ]]; then
    break
  fi
  sleep 0.5
done
denied="$(curl -sS -o "${workdir}/denied.body" -w '%{http_code}' "http://127.0.0.1:${external_port}/v")"
[[ "${denied}" == "403" ]] || {
  printf '%s\n' "Expected origin denial 403 with maintenance off, got ${denied}" >&2
  exit 1
}
assert_contains "$(cat "${workdir}/denied.body")" 'Origin access denied' "origin denial"

printf '%s\n' "Routing checks passed."
