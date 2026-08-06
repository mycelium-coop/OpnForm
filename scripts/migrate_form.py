#!/usr/bin/env python3
"""Interactively migrate one OpnForm form into another account as a draft."""

from __future__ import annotations

import copy
import json
import mimetypes
import re
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Sequence


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_ENV_PATH = SCRIPT_DIR / "form-migration.env"
ENV_KEYS = (
    "ORIGIN_API_URL",
    "ORIGIN_API_KEY",
    "DESTINATION_API_URL",
    "DESTINATION_API_KEY",
)
ENV_TEMPLATE = """# Origin token scopes: workspaces-read, forms-read
ORIGIN_API_URL=
ORIGIN_API_KEY=

# Destination token scopes: workspaces-read, forms-write
DESTINATION_API_URL=
DESTINATION_API_KEY=
"""

MAX_ASSET_BYTES = 5_000_000
DEFAULT_TIMEOUT = 30
RETRYABLE_STATUS_CODES = {429, 500, 502, 503, 504}

# Keep this list aligned with api/app/Http/Requests/UserFormRequest.php. Fields
# tied to an origin instance (slug, custom_domain, and pdf_template_id) are
# intentionally absent.
FORM_WRITABLE_FIELDS = (
    "title",
    "description",
    "tags",
    "language",
    "font_family",
    "theme",
    "presentation_style",
    "width",
    "size",
    "layout_rtl",
    "border_radius",
    "dark_mode",
    "color",
    "uppercase_labels",
    "no_branding",
    "transparent_background",
    "translations",
    "closes_at",
    "closed_text",
    "logo_picture",
    "cover_picture",
    "cover_settings",
    "custom_code",
    "custom_css",
    "submit_button_text",
    "re_fillable",
    "re_fill_button_text",
    "pdf_download_enabled",
    "pdf_download_button_text",
    "submitted_text",
    "redirect_url",
    "database_fields_update",
    "max_submissions_count",
    "max_submissions_reached_text",
    "editable_submissions",
    "editable_submissions_button_text",
    "confetti_on_submission",
    "show_progress_bar",
    "auto_save",
    "auto_focus",
    "enable_partial_submissions",
    "enable_ip_tracking",
    "properties",
    "computed_variables",
    "can_be_indexed",
    "password",
    "use_captcha",
    "captcha_provider",
    "seo_meta",
    "settings",
    "analytics",
)

PathPart = str | int
InputFunction = Callable[[str], str]
OutputFunction = Callable[[str], None]


class MigrationError(Exception):
    """Raised for a user-actionable migration error."""


class ConfigurationError(MigrationError):
    """Raised when the script-specific environment file is incomplete."""


class UserCancelled(MigrationError):
    """Raised when the user cancels an interactive prompt."""


class ApiError(MigrationError):
    """Raised when an OpnForm API request fails."""

    def __init__(self, method: str, path: str, status: int | None, detail: str):
        self.method = method
        self.path = path
        self.status = status
        self.detail = detail
        status_text = f" returned HTTP {status}" if status is not None else " failed"
        super().__init__(f"{method} {path}{status_text}: {detail}")


class AssetTransferError(MigrationError):
    """Raised when an asset cannot be downloaded or uploaded."""


@dataclass(frozen=True)
class MigrationConfig:
    origin_api_url: str
    origin_api_key: str = field(repr=False)
    destination_api_url: str
    destination_api_key: str = field(repr=False)


@dataclass(frozen=True)
class DownloadedAsset:
    contents: bytes
    filename: str
    content_type: str


@dataclass(frozen=True)
class AssetReference:
    path: tuple[PathPart, ...]
    url: str


@dataclass
class AssetTransferResult:
    transferred: dict[str, str] = field(default_factory=dict)
    failures: dict[str, str] = field(default_factory=dict)
    references: dict[str, list[AssetReference]] = field(default_factory=dict)


def parse_env_file(path: Path) -> dict[str, str]:
    """Parse the small dotenv subset needed by this script."""
    if not path.exists():
        return {}

    values: dict[str, str] = {}
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" not in line:
            raise ConfigurationError(f"Invalid line {line_number} in {path}: expected KEY=value.")

        key, raw_value = line.split("=", 1)
        key = key.strip()
        value = raw_value.strip()
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            raise ConfigurationError(f"Invalid environment key on line {line_number} in {path}.")

        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            quote = value[0]
            value = value[1:-1]
            if quote == '"':
                value = value.replace(r"\"", '"').replace(r"\\", "\\")
        else:
            value = re.split(r"\s+#", value, maxsplit=1)[0].rstrip()
        values[key] = value

    return values


def _is_missing_env_value(value: str | None) -> bool:
    if value is None or not value.strip():
        return True
    return value.strip().startswith("<") and value.strip().endswith(">")


def _populate_env_template(path: Path, current: Mapping[str, str], missing: Sequence[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists() or not path.read_text(encoding="utf-8").strip():
        path.write_text(ENV_TEMPLATE, encoding="utf-8")
        path.chmod(0o600)
        return

    absent_keys = [key for key in missing if key not in current]
    if absent_keys:
        with path.open("a", encoding="utf-8") as env_file:
            if path.stat().st_size:
                env_file.write("\n")
            for key in absent_keys:
                env_file.write(f"{key}=\n")
        path.chmod(0o600)


def normalize_base_url(value: str, key_name: str) -> str:
    value = value.strip().rstrip("/")
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ConfigurationError(f"{key_name} must be an absolute http:// or https:// URL.")
    if parsed.query or parsed.fragment:
        raise ConfigurationError(f"{key_name} must not contain a query string or fragment.")
    return value


def load_config(path: Path = DEFAULT_ENV_PATH) -> MigrationConfig:
    try:
        values = parse_env_file(path)
    except OSError as exc:
        raise ConfigurationError(f"Unable to read {path}: {exc}") from exc
    missing = [key for key in ENV_KEYS if _is_missing_env_value(values.get(key))]
    if missing:
        try:
            _populate_env_template(path, values, missing)
        except OSError as exc:
            raise ConfigurationError(f"Unable to prepare {path}: {exc}") from exc
        missing_text = ", ".join(missing)
        raise ConfigurationError(
            f"Configuration is incomplete ({missing_text}). Fill out {path} and run the script again. "
            "The origin token needs workspaces-read and forms-read; the destination token needs "
            "workspaces-read and forms-write."
        )

    return MigrationConfig(
        origin_api_url=normalize_base_url(values["ORIGIN_API_URL"], "ORIGIN_API_URL"),
        origin_api_key=values["ORIGIN_API_KEY"].strip(),
        destination_api_url=normalize_base_url(values["DESTINATION_API_URL"], "DESTINATION_API_URL"),
        destination_api_key=values["DESTINATION_API_KEY"].strip(),
    )


def redact(text: str, secrets_to_hide: Iterable[str]) -> str:
    redacted = text
    for secret in secrets_to_hide:
        if secret:
            redacted = redacted.replace(secret, "[REDACTED]")
    return redacted


class ApiClient:
    """Minimal JSON and asset client for OpnForm's HTTP API."""

    def __init__(
        self,
        base_url: str,
        api_key: str,
        *,
        timeout: int = DEFAULT_TIMEOUT,
        max_retries: int = 2,
        opener: Callable[..., Any] | None = None,
        sleeper: Callable[[float], None] = time.sleep,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.timeout = timeout
        self.max_retries = max_retries
        self._opener = opener or urllib.request.urlopen
        self._sleeper = sleeper

    def _url(self, path: str) -> str:
        return f"{self.base_url}/{path.lstrip('/')}"

    def _error_detail(self, body: bytes, fallback: str) -> str:
        detail = fallback
        if body:
            try:
                payload = json.loads(body.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                decoded = body.decode("utf-8", errors="replace").strip()
                detail = decoded or fallback
            else:
                if isinstance(payload, dict):
                    message = payload.get("message") or payload.get("error") or fallback
                    errors = payload.get("errors")
                    if errors:
                        message = f"{message} ({json.dumps(errors, ensure_ascii=False)})"
                    detail = str(message)
                else:
                    detail = str(payload)
        return redact(detail[:1000], [self.api_key])

    def request_json(
        self,
        method: str,
        path: str,
        *,
        payload: Any | None = None,
        raw_data: bytes | None = None,
        headers: Mapping[str, str] | None = None,
        authenticated: bool = True,
    ) -> Any:
        if payload is not None and raw_data is not None:
            raise ValueError("payload and raw_data are mutually exclusive")

        request_headers = {
            "Accept": "application/json",
            "User-Agent": "opnform-form-migration/1.0",
        }
        data = raw_data
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            request_headers["Content-Type"] = "application/json"
        if authenticated:
            request_headers["Authorization"] = f"Bearer {self.api_key}"
        if headers:
            request_headers.update(headers)

        url = self._url(path)
        for attempt in range(self.max_retries + 1):
            request = urllib.request.Request(url, data=data, headers=request_headers, method=method)
            try:
                with self._opener(request, timeout=self.timeout) as response:
                    body = response.read()
            except urllib.error.HTTPError as exc:
                body = exc.read()
                if exc.code in RETRYABLE_STATUS_CODES and attempt < self.max_retries:
                    retry_after = exc.headers.get("Retry-After") if exc.headers else None
                    try:
                        delay = min(max(float(retry_after), 0.0), 30.0) if retry_after else 2**attempt
                    except ValueError:
                        delay = 2**attempt
                    self._sleeper(delay)
                    continue
                detail = self._error_detail(body, exc.reason or "API request failed")
                raise ApiError(method, path, exc.code, detail) from exc
            except (urllib.error.URLError, TimeoutError) as exc:
                if attempt < self.max_retries:
                    self._sleeper(2**attempt)
                    continue
                reason = getattr(exc, "reason", exc)
                raise ApiError(method, path, None, redact(str(reason), [self.api_key])) from exc

            if not body:
                raise ApiError(method, path, None, "API returned an empty response.")
            try:
                return json.loads(body.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise ApiError(method, path, None, "API returned malformed JSON.") from exc

        raise ApiError(method, path, None, "API request failed after retries.")

    def download_asset(self, url: str) -> DownloadedAsset:
        """Download a public asset without forwarding the API key."""
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise AssetTransferError("Asset URL is not an absolute HTTP(S) URL.")

        request = urllib.request.Request(
            url,
            headers={"Accept": "image/*,*/*;q=0.8", "User-Agent": "opnform-form-migration/1.0"},
            method="GET",
        )
        try:
            with self._opener(request, timeout=self.timeout) as response:
                content_length = response.headers.get("Content-Length")
                if content_length:
                    try:
                        if int(content_length) > MAX_ASSET_BYTES:
                            raise AssetTransferError("Asset exceeds OpnForm's 5 MB form-asset limit.")
                    except ValueError:
                        pass
                contents = response.read(MAX_ASSET_BYTES + 1)
                content_type = response.headers.get_content_type()
        except AssetTransferError:
            raise
        except urllib.error.HTTPError as exc:
            raise AssetTransferError(f"Download returned HTTP {exc.code}.") from exc
        except (urllib.error.URLError, TimeoutError) as exc:
            reason = getattr(exc, "reason", exc)
            raise AssetTransferError(f"Download failed: {reason}") from exc

        if len(contents) > MAX_ASSET_BYTES:
            raise AssetTransferError("Asset exceeds OpnForm's 5 MB form-asset limit.")
        if not contents:
            raise AssetTransferError("Asset download was empty.")

        filename = urllib.parse.unquote(Path(parsed.path).name) or "form-asset"
        filename = safe_asset_filename(filename, content_type)
        return DownloadedAsset(contents=contents, filename=filename, content_type=content_type)

    def upload_form_asset(self, asset: DownloadedAsset) -> str:
        boundary = f"----opnform-{secrets.token_hex(16)}"
        safe_filename = asset.filename.replace('"', "")
        multipart = (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="file"; filename="{safe_filename}"\r\n'
            f"Content-Type: {asset.content_type}\r\n\r\n"
        ).encode("utf-8") + asset.contents + f"\r\n--{boundary}--\r\n".encode("ascii")

        temporary = self.request_json(
            "POST",
            "/upload-file",
            raw_data=multipart,
            headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
            authenticated=False,
        )
        if not isinstance(temporary, dict) or not temporary.get("uuid"):
            raise AssetTransferError("Temporary upload returned an unexpected response.")

        filename = Path(asset.filename)
        stem = filename.stem[:50] or "form-asset"
        extension = filename.suffix.lower()
        temporary_name = f"{stem}_{temporary['uuid']}{extension}"
        finalized = self.request_json(
            "POST",
            "/open/forms/assets/upload",
            payload={"url": temporary_name, "type": asset.content_type},
        )
        if not isinstance(finalized, dict) or not isinstance(finalized.get("url"), str):
            raise AssetTransferError("Permanent asset upload returned an unexpected response.")
        return finalized["url"]


def safe_asset_filename(filename: str, content_type: str) -> str:
    filename = re.sub(r"[^A-Za-z0-9._-]+", "-", filename).strip(".-") or "form-asset"
    path = Path(filename)
    extension = path.suffix.lower()
    if not extension or not re.fullmatch(r"\.[a-z0-9]{1,10}", extension):
        extension = mimetypes.guess_extension(content_type.split(";", 1)[0].strip()) or ".bin"
        if extension == ".jpe":
            extension = ".jpg"
    stem = path.stem[:50].strip(".-") or "form-asset"
    return f"{stem}{extension}"


def _expect_list(payload: Any, description: str) -> list[dict[str, Any]]:
    if isinstance(payload, dict) and isinstance(payload.get("data"), list):
        payload = payload["data"]
    if not isinstance(payload, list) or not all(isinstance(item, dict) for item in payload):
        raise MigrationError(f"The API returned an unexpected {description} response.")
    return payload


def list_workspaces(client: ApiClient) -> list[dict[str, Any]]:
    return _expect_list(client.request_json("GET", "/open/workspaces"), "workspace list")


def list_workspace_forms(client: ApiClient, workspace_id: Any) -> list[dict[str, Any]]:
    forms: list[dict[str, Any]] = []
    page = 1
    while page <= 10_000:
        path = f"/open/workspaces/{urllib.parse.quote(str(workspace_id), safe='')}/forms?per_page=100&page={page}"
        payload = client.request_json("GET", path)
        if not isinstance(payload, dict) or not isinstance(payload.get("data"), list):
            raise MigrationError("The API returned an unexpected paginated form-list response.")
        page_forms = payload["data"]
        if not all(isinstance(item, dict) for item in page_forms):
            raise MigrationError("The API returned an invalid form in the form list.")
        forms.extend(page_forms)

        meta = payload.get("meta") if isinstance(payload.get("meta"), dict) else {}
        try:
            current_page = int(meta.get("current_page", page))
            last_page = int(meta["last_page"]) if meta.get("last_page") is not None else None
        except (TypeError, ValueError) as exc:
            raise MigrationError("The API returned invalid form pagination metadata.") from exc
        if last_page is not None and current_page >= last_page:
            break
        if len(page_forms) < 100 and last_page is None:
            break
        if not page_forms:
            break
        page += 1
    else:
        raise MigrationError("Form pagination exceeded the safety limit.")
    return forms


def list_all_origin_forms(
    client: ApiClient, workspaces: Sequence[Mapping[str, Any]]
) -> list[dict[str, Any]]:
    available_forms: list[dict[str, Any]] = []
    for workspace in workspaces:
        workspace_id = workspace.get("id")
        if workspace_id is None:
            raise MigrationError("An origin workspace is missing its ID.")
        workspace_name = str(workspace.get("name") or f"Workspace {workspace_id}")
        for form in list_workspace_forms(client, workspace_id):
            item = dict(form)
            item["_workspace_name"] = workspace_name
            item["_workspace_id"] = workspace_id
            available_forms.append(item)
    return available_forms


def writable_workspaces(workspaces: Sequence[Mapping[str, Any]]) -> list[dict[str, Any]]:
    return [dict(workspace) for workspace in workspaces if not bool(workspace.get("is_readonly", False))]


def choose_numbered(
    items: Sequence[Any],
    heading: str,
    formatter: Callable[[Any], str],
    *,
    input_fn: InputFunction = input,
    output: OutputFunction = print,
) -> Any:
    if not items:
        raise MigrationError(f"No {heading.lower()} are available.")
    output(heading)
    for index, item in enumerate(items, start=1):
        output(f"  {index}. {formatter(item)}")

    while True:
        choice = input_fn("Enter a number (or q to cancel): ").strip()
        if choice.lower() in {"q", "quit", "cancel"}:
            raise UserCancelled("Migration cancelled.")
        try:
            selected_index = int(choice)
        except ValueError:
            output("Please enter one of the displayed numbers, or q to cancel.")
            continue
        if 1 <= selected_index <= len(items):
            return items[selected_index - 1]
        output("Please enter one of the displayed numbers, or q to cancel.")


def format_form_choice(form: Mapping[str, Any]) -> str:
    return (
        f"{form.get('title') or '(Untitled)'} — {form.get('_workspace_name') or 'Unknown workspace'} "
        f"[{form.get('visibility') or 'unknown'}] (slug: {form.get('slug') or 'unknown'})"
    )


def format_workspace_choice(workspace: Mapping[str, Any]) -> str:
    return f"{workspace.get('name') or '(Unnamed workspace)'} (ID: {workspace.get('id')})"


def extract_form_response(payload: Any) -> dict[str, Any]:
    if isinstance(payload, dict) and isinstance(payload.get("form"), dict):
        return payload["form"]
    if isinstance(payload, dict) and isinstance(payload.get("data"), dict):
        return payload["data"]
    if isinstance(payload, dict) and ("id" in payload or "title" in payload):
        return payload
    raise MigrationError("The API returned an unexpected form response.")


def fetch_form(client: ApiClient, slug: Any) -> dict[str, Any]:
    path = f"/open/forms/{urllib.parse.quote(str(slug), safe='')}"
    return extract_form_response(client.request_json("GET", path))


def build_form_payload(source_form: Mapping[str, Any], destination_workspace_id: Any) -> dict[str, Any]:
    payload = {
        key: copy.deepcopy(source_form[key])
        for key in FORM_WRITABLE_FIELDS
        if key in source_form
    }
    payload["workspace_id"] = destination_workspace_id
    payload["visibility"] = "draft"
    return payload


def _is_http_url(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    parsed = urllib.parse.urlsplit(value)
    return parsed.scheme in {"http", "https"} and bool(parsed.netloc)


def discover_asset_references(payload: Mapping[str, Any]) -> list[AssetReference]:
    references: list[AssetReference] = []
    for key in ("cover_picture", "logo_picture"):
        value = payload.get(key)
        if _is_http_url(value):
            references.append(AssetReference((key,), value))

    def walk(value: Any, path: tuple[PathPart, ...]) -> None:
        if isinstance(value, dict):
            for key, nested in value.items():
                nested_path = path + (key,)
                if key == "image" and _is_http_url(nested):
                    references.append(AssetReference(nested_path, nested))
                elif key == "image" and isinstance(nested, dict) and _is_http_url(nested.get("url")):
                    references.append(AssetReference(nested_path + ("url",), nested["url"]))
                walk(nested, nested_path)
        elif isinstance(value, list):
            for index, nested in enumerate(value):
                walk(nested, path + (index,))

    walk(payload.get("properties", []), ("properties",))

    seen: set[tuple[tuple[PathPart, ...], str]] = set()
    unique: list[AssetReference] = []
    for reference in references:
        identity = (reference.path, reference.url)
        if identity not in seen:
            seen.add(identity)
            unique.append(reference)
    return unique


def group_asset_references(references: Iterable[AssetReference]) -> dict[str, list[AssetReference]]:
    grouped: dict[str, list[AssetReference]] = {}
    for reference in references:
        grouped.setdefault(reference.url, []).append(reference)
    return grouped


def is_origin_hosted_asset(url: str, origin_base_url: str) -> bool:
    asset = urllib.parse.urlsplit(url)
    origin = urllib.parse.urlsplit(origin_base_url)
    if asset.scheme.lower() != origin.scheme.lower() or asset.netloc.lower() != origin.netloc.lower():
        return False
    return re.search(r"(?:^|/)forms/assets/[^/]+$", asset.path) is not None


def set_path(root: Any, path: Sequence[PathPart], value: Any) -> None:
    target = root
    for part in path[:-1]:
        target = target[part]
    target[path[-1]] = value


def format_reference_path(path: Sequence[PathPart]) -> str:
    rendered = ""
    for part in path:
        if isinstance(part, int):
            rendered += f"[{part}]"
        elif rendered:
            rendered += f".{part}"
        else:
            rendered = part
    return rendered


def transfer_assets(
    payload: dict[str, Any],
    references: Iterable[AssetReference],
    origin_client: ApiClient,
    destination_client: ApiClient,
    origin_base_url: str,
) -> AssetTransferResult:
    grouped = group_asset_references(references)
    result = AssetTransferResult(references=grouped)
    for source_url, source_references in grouped.items():
        if not is_origin_hosted_asset(source_url, origin_base_url):
            continue
        try:
            asset = origin_client.download_asset(source_url)
            destination_url = destination_client.upload_form_asset(asset)
        except Exception as exc:
            result.failures[source_url] = redact(
                str(exc) or exc.__class__.__name__,
                [getattr(origin_client, "api_key", ""), getattr(destination_client, "api_key", "")],
            )
            continue

        result.transferred[source_url] = destination_url
        for reference in source_references:
            set_path(payload, reference.path, destination_url)
    return result


def flatten_cleaning_messages(value: Any) -> list[str]:
    messages: list[str] = []
    if isinstance(value, str):
        messages.append(value)
    elif isinstance(value, dict):
        for nested in value.values():
            messages.extend(flatten_cleaning_messages(nested))
    elif isinstance(value, list):
        for nested in value:
            messages.extend(flatten_cleaning_messages(nested))
    return messages


def confirm_migration(
    form: Mapping[str, Any],
    workspace: Mapping[str, Any],
    origin_asset_count: int,
    *,
    input_fn: InputFunction = input,
    output: OutputFunction = print,
) -> None:
    output("")
    output(f"Selected form: {form.get('title') or '(Untitled)'}")
    output(f"Destination workspace: {workspace.get('name') or workspace.get('id')}")
    output("Destination visibility: draft")
    output(f"Origin-hosted assets to transfer: {origin_asset_count}")
    answer = input_fn("Create this draft on the destination account? [y/N]: ").strip().lower()
    if answer not in {"y", "yes"}:
        raise UserCancelled("Migration cancelled before creating the destination form.")


def _create_form(client: ApiClient, payload: Mapping[str, Any]) -> tuple[dict[str, Any], Any]:
    response = client.request_json("POST", "/open/forms", payload=payload)
    return extract_form_response(response), response


def _update_form(client: ApiClient, form_id: Any, payload: Mapping[str, Any]) -> tuple[dict[str, Any], Any]:
    path = f"/open/forms/{urllib.parse.quote(str(form_id), safe='')}"
    response = client.request_json("PUT", path, payload=payload)
    return extract_form_response(response), response


def run_migration(
    config: MigrationConfig,
    *,
    input_fn: InputFunction = input,
    output: OutputFunction = print,
    client_factory: Callable[[str, str], ApiClient] = ApiClient,
) -> dict[str, Any]:
    origin_client = client_factory(config.origin_api_url, config.origin_api_key)
    destination_client = client_factory(config.destination_api_url, config.destination_api_key)

    output("Loading origin workspaces and forms...")
    origin_workspaces = list_workspaces(origin_client)
    if not origin_workspaces:
        raise MigrationError("The origin account has no workspaces.")
    origin_forms = list_all_origin_forms(origin_client, origin_workspaces)
    if not origin_forms:
        raise MigrationError("The origin account has no forms to migrate.")

    selected_summary = choose_numbered(
        origin_forms,
        "Available origin forms",
        format_form_choice,
        input_fn=input_fn,
        output=output,
    )
    slug = selected_summary.get("slug")
    if not slug:
        raise MigrationError("The selected form is missing its slug.")
    source_form = fetch_form(origin_client, slug)

    output("Loading destination workspaces...")
    destination_workspaces = writable_workspaces(list_workspaces(destination_client))
    if not destination_workspaces:
        raise MigrationError("The destination account has no writable workspaces.")
    if len(destination_workspaces) == 1:
        destination_workspace = destination_workspaces[0]
        output(f"Using destination workspace: {format_workspace_choice(destination_workspace)}")
    else:
        destination_workspace = choose_numbered(
            destination_workspaces,
            "Writable destination workspaces",
            format_workspace_choice,
            input_fn=input_fn,
            output=output,
        )

    workspace_id = destination_workspace.get("id")
    if workspace_id is None:
        raise MigrationError("The selected destination workspace is missing its ID.")
    payload = build_form_payload(source_form, workspace_id)
    references = discover_asset_references(payload)
    origin_asset_count = len(
        {
            reference.url
            for reference in references
            if is_origin_hosted_asset(reference.url, config.origin_api_url)
        }
    )
    confirm_migration(
        source_form,
        destination_workspace,
        origin_asset_count,
        input_fn=input_fn,
        output=output,
    )

    output("Creating destination draft...")
    created_form, create_response = _create_form(destination_client, payload)
    created_id = created_form.get("id")
    if created_id is None:
        raise MigrationError("The destination API created a form but did not return its ID.")
    if created_form.get("visibility") != "draft":
        raise MigrationError("The destination API did not confirm that the created form is a draft.")

    transfer_result = transfer_assets(
        payload,
        references,
        origin_client,
        destination_client,
        config.origin_api_url,
    )
    updated_form = created_form
    update_response: Any = None
    effective_transfers = dict(transfer_result.transferred)
    if transfer_result.transferred:
        payload["visibility"] = "draft"
        output(f"Applying {len(transfer_result.transferred)} transferred asset(s) to the draft...")
        try:
            updated_form, update_response = _update_form(destination_client, created_id, payload)
            if updated_form.get("visibility") != "draft":
                raise MigrationError("The destination API did not keep the updated form in draft mode.")
        except MigrationError as exc:
            reason = f"Transferred, but the draft update failed: {exc}"
            for source_url in effective_transfers:
                transfer_result.failures[source_url] = reason
            effective_transfers.clear()
            output(f"Warning: {reason}")

    cleaning_sources = [created_form.get("cleanings"), updated_form.get("cleanings")]
    if isinstance(create_response, dict):
        cleaning_sources.append(create_response.get("cleanings"))
    if isinstance(update_response, dict):
        cleaning_sources.append(update_response.get("cleanings"))
    cleanings: list[str] = []
    for cleaning_source in cleaning_sources:
        cleanings.extend(flatten_cleaning_messages(cleaning_source))
    cleanings = list(dict.fromkeys(cleanings))

    output("")
    output("Migration complete.")
    output(f"  Title: {updated_form.get('title') or source_form.get('title') or '(Untitled)'}")
    output(f"  Destination form ID: {created_id}")
    if updated_form.get("slug"):
        output(f"  Destination slug: {updated_form['slug']}")
    output("  Visibility: draft")
    output(f"  Assets re-hosted: {len(effective_transfers)}")

    if source_form.get("custom_domain"):
        output("  Note: The origin custom domain was not copied; configure it in the destination account.")
    if source_form.get("pdf_template_id"):
        output("  Note: The origin PDF template was not copied; select or recreate it in the destination account.")
    if cleanings:
        output("  Destination plan/API warnings:")
        for message in cleanings:
            output(f"    - {message}")

    if transfer_result.failures:
        output("")
        output("Some origin-hosted assets need manual replacement:")
        for source_url, reason in transfer_result.failures.items():
            paths = ", ".join(
                format_reference_path(reference.path)
                for reference in transfer_result.references.get(source_url, [])
            )
            output(f"  - Location: {paths or 'unknown'}")
            output(f"    Download: {source_url}")
            output(f"    Reason: {reason}")
        output("Download each listed asset, open the destination draft, and upload it at the listed location.")

    output("")
    output("Visit the destination account and verify the form carefully before publishing it.")
    output("Submissions and integrations were not copied.")

    return {
        "form": updated_form,
        "created_form": created_form,
        "transferred_assets": effective_transfers,
        "asset_failures": transfer_result.failures,
        "cleanings": cleanings,
    }


def main() -> int:
    try:
        config = load_config()
        run_migration(config)
    except UserCancelled as exc:
        print(str(exc))
        return 0
    except MigrationError as exc:
        secrets_to_hide: list[str] = []
        if "config" in locals():
            secrets_to_hide = [config.origin_api_key, config.destination_api_key]
        print(f"Error: {redact(str(exc), secrets_to_hide)}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nMigration cancelled.")
        return 130
    except Exception as exc:
        secrets_to_hide = []
        if "config" in locals():
            secrets_to_hide = [config.origin_api_key, config.destination_api_key]
        print(f"Error: {redact(str(exc) or exc.__class__.__name__, secrets_to_hide)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
