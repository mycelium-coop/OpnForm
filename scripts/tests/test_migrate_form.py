from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
import urllib.error
from email.message import Message
from pathlib import Path
from typing import Any


SCRIPTS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS_DIR))

import migrate_form  # noqa: E402


class FakeResponse:
    def __init__(self, body: bytes, headers: Message | None = None):
        self.body = body
        self.headers = headers or Message()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        return False

    def read(self, size: int = -1) -> bytes:
        return self.body if size < 0 else self.body[:size]


class QueueOpener:
    def __init__(self, *responses: Any):
        self.responses = list(responses)
        self.requests: list[Any] = []

    def __call__(self, request, timeout):
        self.requests.append((request, timeout))
        response = self.responses.pop(0)
        if isinstance(response, BaseException):
            raise response
        return response


def http_error(status: int, body: dict[str, Any], headers: Message | None = None):
    return urllib.error.HTTPError(
        "https://api.example.test/open/forms",
        status,
        "Request failed",
        headers or Message(),
        io.BytesIO(json.dumps(body).encode("utf-8")),
    )


class ConfigTests(unittest.TestCase):
    def test_missing_env_file_is_created_and_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "form-migration.env"

            with self.assertRaises(migrate_form.ConfigurationError) as context:
                migrate_form.load_config(path)

            self.assertTrue(path.exists())
            contents = path.read_text(encoding="utf-8")
            for key in migrate_form.ENV_KEYS:
                self.assertIn(f"{key}=", contents)
            self.assertIn("run the script again", str(context.exception))

    def test_empty_env_file_is_populated(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "form-migration.env"
            path.write_text("\n", encoding="utf-8")

            with self.assertRaises(migrate_form.ConfigurationError):
                migrate_form.load_config(path)

            self.assertEqual(path.read_text(encoding="utf-8"), migrate_form.ENV_TEMPLATE)

    def test_incomplete_env_preserves_values_and_adds_absent_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "form-migration.env"
            path.write_text(
                "ORIGIN_API_URL=https://origin.test\nORIGIN_API_KEY=keep-me\n",
                encoding="utf-8",
            )

            with self.assertRaises(migrate_form.ConfigurationError):
                migrate_form.load_config(path)

            contents = path.read_text(encoding="utf-8")
            self.assertIn("ORIGIN_API_KEY=keep-me", contents)
            self.assertIn("DESTINATION_API_URL=", contents)
            self.assertIn("DESTINATION_API_KEY=", contents)

    def test_quoted_values_and_inline_comments_are_parsed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "form-migration.env"
            path.write_text(
                '\n'.join(
                    [
                        'export ORIGIN_API_URL="https://origin.test/api/"',
                        "ORIGIN_API_KEY='origin token'",
                        "DESTINATION_API_URL=https://destination.test # comment",
                        'DESTINATION_API_KEY="destination-token"',
                    ]
                ),
                encoding="utf-8",
            )

            config = migrate_form.load_config(path)

            self.assertEqual(config.origin_api_url, "https://origin.test/api")
            self.assertEqual(config.origin_api_key, "origin token")
            self.assertEqual(config.destination_api_url, "https://destination.test")
            self.assertNotIn("origin token", repr(config))
            self.assertNotIn("destination-token", repr(config))


class PayloadAndSelectionTests(unittest.TestCase):
    def test_payload_preserves_writable_fields_and_forces_draft(self):
        source = {key: f"value-{key}" for key in migrate_form.FORM_WRITABLE_FIELDS}
        source.update(
            {
                "visibility": "public",
                "properties": [{"id": "field-1", "type": "short_text", "name": "Name"}],
                "id": 12,
                "slug": "origin-slug",
                "workspace_id": 4,
                "custom_domain": "forms.origin.test",
                "pdf_template_id": 99,
                "views_count": 100,
            }
        )

        payload = migrate_form.build_form_payload(source, 88)

        self.assertEqual(payload["visibility"], "draft")
        self.assertEqual(payload["workspace_id"], 88)
        self.assertEqual(payload["font_family"], "value-font_family")
        self.assertEqual(payload["computed_variables"], "value-computed_variables")
        for excluded in ("id", "slug", "custom_domain", "pdf_template_id", "views_count"):
            self.assertNotIn(excluded, payload)
        payload["properties"][0]["name"] = "Changed"
        self.assertEqual(source["properties"][0]["name"], "Name")

    def test_choose_numbered_reprompts_until_valid(self):
        answers = iter(["word", "9", "2"])
        output: list[str] = []

        selected = migrate_form.choose_numbered(
            ["first", "second"],
            "Choices",
            str,
            input_fn=lambda _: next(answers),
            output=output.append,
        )

        self.assertEqual(selected, "second")
        self.assertEqual(sum("Please enter" in line for line in output), 2)

    def test_choose_numbered_can_cancel(self):
        with self.assertRaises(migrate_form.UserCancelled):
            migrate_form.choose_numbered(
                ["first"], "Choices", str, input_fn=lambda _: "q", output=lambda _: None
            )

    def test_readonly_destination_workspaces_are_removed(self):
        workspaces = [
            {"id": 1, "name": "Writable", "is_readonly": False},
            {"id": 2, "name": "Readonly", "is_readonly": True},
        ]

        self.assertEqual([item["id"] for item in migrate_form.writable_workspaces(workspaces)], [1])


class ApiTests(unittest.TestCase):
    def test_paginated_form_listing_requests_every_page(self):
        class StubClient:
            def __init__(self):
                self.paths = []

            def request_json(self, method, path):
                self.paths.append(path)
                page = len(self.paths)
                return {
                    "data": [{"id": page, "slug": f"form-{page}"}],
                    "meta": {"current_page": page, "last_page": 2},
                }

        client = StubClient()
        forms = migrate_form.list_workspace_forms(client, 7)

        self.assertEqual([form["id"] for form in forms], [1, 2])
        self.assertIn("per_page=100&page=1", client.paths[0])
        self.assertIn("per_page=100&page=2", client.paths[1])

    def test_form_response_accepts_direct_wrapped_and_resource_shapes(self):
        direct = {"id": 1, "title": "Direct"}
        self.assertEqual(migrate_form.extract_form_response(direct), direct)
        self.assertEqual(migrate_form.extract_form_response({"form": direct}), direct)
        self.assertEqual(migrate_form.extract_form_response({"data": direct}), direct)

    def test_malformed_json_is_reported(self):
        opener = QueueOpener(FakeResponse(b"not json"))
        client = migrate_form.ApiClient(
            "https://api.example.test", "token", opener=opener, max_retries=0
        )

        with self.assertRaisesRegex(migrate_form.ApiError, "malformed JSON"):
            client.request_json("GET", "/open/workspaces")

    def test_http_error_redacts_api_key(self):
        token = "secret-api-token"
        opener = QueueOpener(http_error(401, {"message": f"Invalid {token}"}))
        client = migrate_form.ApiClient(
            "https://api.example.test", token, opener=opener, max_retries=0
        )

        with self.assertRaises(migrate_form.ApiError) as context:
            client.request_json("GET", "/open/workspaces")

        self.assertNotIn(token, str(context.exception))
        self.assertIn("[REDACTED]", str(context.exception))

    def test_validation_error_includes_actionable_field_details(self):
        opener = QueueOpener(
            http_error(
                422,
                {
                    "message": "Validation failed.",
                    "errors": {"properties": ["The properties field is invalid."]},
                },
            )
        )
        client = migrate_form.ApiClient(
            "https://api.example.test", "token", opener=opener, max_retries=0
        )

        with self.assertRaises(migrate_form.ApiError) as context:
            client.request_json("POST", "/open/forms", payload={})

        self.assertEqual(context.exception.status, 422)
        self.assertIn("properties", str(context.exception))
        self.assertIn("invalid", str(context.exception))

    def test_rate_limit_is_retried(self):
        headers = Message()
        headers["Retry-After"] = "0"
        opener = QueueOpener(
            http_error(429, {"message": "Slow down"}, headers),
            FakeResponse(b'{"ok": true}'),
        )
        sleeps: list[float] = []
        client = migrate_form.ApiClient(
            "https://api.example.test",
            "token",
            opener=opener,
            max_retries=1,
            sleeper=sleeps.append,
        )

        self.assertEqual(client.request_json("GET", "/open/workspaces"), {"ok": True})
        self.assertEqual(len(opener.requests), 2)
        self.assertEqual(sleeps, [0.0])


class AssetTests(unittest.TestCase):
    ORIGIN = "https://origin.test"
    COVER = "https://origin.test/forms/assets/cover.png"
    OPTION = "https://origin.test/forms/assets/option.jpg"
    EXTERNAL = "https://images.example.test/logo.svg"

    def payload(self):
        return {
            "cover_picture": self.COVER,
            "logo_picture": self.EXTERNAL,
            "properties": [
                {"id": "one", "image": {"url": self.COVER, "alt": "Cover"}},
                {
                    "id": "two",
                    "select": {"options": [{"id": "a", "name": "A", "image": self.OPTION}]},
                },
            ],
        }

    def test_asset_discovery_finds_media_and_deduplicates_by_location(self):
        references = migrate_form.discover_asset_references(self.payload())
        grouped = migrate_form.group_asset_references(references)

        self.assertEqual(len(references), 4)
        self.assertEqual(len(grouped[self.COVER]), 2)
        self.assertEqual(
            migrate_form.format_reference_path(grouped[self.OPTION][0].path),
            "properties[1].select.options[0].image",
        )

    def test_origin_asset_detection_rejects_external_urls(self):
        self.assertTrue(migrate_form.is_origin_hosted_asset(self.COVER, self.ORIGIN))
        self.assertFalse(migrate_form.is_origin_hosted_asset(self.EXTERNAL, self.ORIGIN))
        self.assertFalse(
            migrate_form.is_origin_hosted_asset(
                "https://origin.test/forms/not-assets/cover.png", self.ORIGIN
            )
        )

    def test_transfer_deduplicates_success_and_keeps_failures(self):
        payload = self.payload()
        references = migrate_form.discover_asset_references(payload)

        class OriginClient:
            def __init__(self):
                self.calls = []

            def download_asset(self, url):
                self.calls.append(url)
                if url == AssetTests.OPTION:
                    raise migrate_form.AssetTransferError("download unavailable")
                return migrate_form.DownloadedAsset(b"image", "cover.png", "image/png")

        class DestinationClient:
            def __init__(self):
                self.calls = []

            def upload_form_asset(self, asset):
                self.calls.append(asset)
                return "https://destination.test/forms/assets/new-cover.png"

        origin = OriginClient()
        destination = DestinationClient()
        result = migrate_form.transfer_assets(
            payload, references, origin, destination, self.ORIGIN
        )

        self.assertEqual(origin.calls, [self.COVER, self.OPTION])
        self.assertEqual(len(destination.calls), 1)
        self.assertEqual(
            payload["properties"][0]["image"]["url"],
            "https://destination.test/forms/assets/new-cover.png",
        )
        self.assertEqual(
            payload["cover_picture"], "https://destination.test/forms/assets/new-cover.png"
        )
        self.assertEqual(payload["properties"][1]["select"]["options"][0]["image"], self.OPTION)
        self.assertEqual(payload["logo_picture"], self.EXTERNAL)
        self.assertIn(self.OPTION, result.failures)

    def test_download_rejects_asset_larger_than_limit(self):
        headers = Message()
        headers["Content-Length"] = str(migrate_form.MAX_ASSET_BYTES + 1)
        headers["Content-Type"] = "image/png"
        client = migrate_form.ApiClient(
            self.ORIGIN,
            "do-not-forward",
            opener=QueueOpener(FakeResponse(b"ignored", headers)),
            max_retries=0,
        )

        with self.assertRaisesRegex(migrate_form.AssetTransferError, "5 MB"):
            client.download_asset(self.COVER)

    def test_download_does_not_send_authorization_header(self):
        headers = Message()
        headers["Content-Type"] = "image/png"
        opener = QueueOpener(FakeResponse(b"image", headers))
        client = migrate_form.ApiClient(
            self.ORIGIN, "do-not-forward", opener=opener, max_retries=0
        )

        client.download_asset(self.COVER)

        request = opener.requests[0][0]
        self.assertIsNone(request.get_header("Authorization"))

    def test_upload_uses_temporary_then_permanent_endpoints(self):
        class StubClient(migrate_form.ApiClient):
            def __init__(self):
                super().__init__("https://destination.test", "token")
                self.calls = []

            def request_json(self, method, path, **kwargs):
                self.calls.append((method, path, kwargs))
                if path == "/upload-file":
                    return {"uuid": "12345678-1234-1234-1234-123456789abc"}
                return {"url": "https://destination.test/forms/assets/final.png"}

        client = StubClient()
        result = client.upload_form_asset(
            migrate_form.DownloadedAsset(b"image", "source.png", "image/png")
        )

        self.assertEqual(result, "https://destination.test/forms/assets/final.png")
        self.assertEqual([call[1] for call in client.calls], ["/upload-file", "/open/forms/assets/upload"])
        self.assertFalse(client.calls[0][2]["authenticated"])
        self.assertIn(b'filename="source.png"', client.calls[0][2]["raw_data"])
        self.assertEqual(
            client.calls[1][2]["payload"]["url"],
            "source_12345678-1234-1234-1234-123456789abc.png",
        )


class EndToEndWorkflowTests(unittest.TestCase):
    def test_workflow_creates_and_updates_only_as_draft(self):
        origin_url = "https://origin.test"
        destination_url = "https://destination.test"
        source_asset = f"{origin_url}/forms/assets/cover.png"

        class OriginClient:
            def __init__(self):
                self.downloads = []

            def request_json(self, method, path, **kwargs):
                if path == "/open/workspaces":
                    return [{"id": 1, "name": "Origin"}]
                if path.startswith("/open/workspaces/1/forms"):
                    return {
                        "data": [{"id": 2, "slug": "survey", "title": "Survey", "visibility": "public"}],
                        "meta": {"current_page": 1, "last_page": 1},
                    }
                if path == "/open/forms/survey":
                    return {
                        "id": 2,
                        "slug": "survey",
                        "title": "Survey",
                        "visibility": "public",
                        "language": "en",
                        "properties": [],
                        "cover_picture": source_asset,
                    }
                raise AssertionError(path)

            def download_asset(self, url):
                self.downloads.append(url)
                return migrate_form.DownloadedAsset(b"image", "cover.png", "image/png")

        class DestinationClient:
            def __init__(self):
                self.writes = []

            def request_json(self, method, path, **kwargs):
                if path == "/open/workspaces":
                    return [{"id": 9, "name": "Destination", "is_readonly": False}]
                if path == "/open/forms" and method == "POST":
                    self.writes.append((method, path, kwargs["payload"]))
                    self._assert_draft(kwargs["payload"])
                    return {"form": {"id": 44, "slug": "new-survey", "title": "Survey", "visibility": "draft"}}
                if path == "/open/forms/44" and method == "PUT":
                    self.writes.append((method, path, kwargs["payload"]))
                    self._assert_draft(kwargs["payload"])
                    return {"form": {"id": 44, "slug": "new-survey", "title": "Survey", "visibility": "draft"}}
                raise AssertionError(path)

            def upload_form_asset(self, asset):
                return f"{destination_url}/forms/assets/cover.png"

            @staticmethod
            def _assert_draft(payload):
                if payload.get("visibility") != "draft":
                    raise AssertionError("Form write was not a draft")

        origin_client = OriginClient()
        destination_client = DestinationClient()

        def factory(url, _key):
            return origin_client if url == origin_url else destination_client

        answers = iter(["1", "yes"])
        result = migrate_form.run_migration(
            migrate_form.MigrationConfig(origin_url, "origin-key", destination_url, "destination-key"),
            input_fn=lambda _: next(answers),
            output=lambda _: None,
            client_factory=factory,
        )

        self.assertEqual(len(destination_client.writes), 2)
        self.assertTrue(all(write[2]["visibility"] == "draft" for write in destination_client.writes))
        self.assertEqual(destination_client.writes[0][2]["workspace_id"], 9)
        self.assertNotIn("slug", destination_client.writes[0][2])
        self.assertEqual(len(result["transferred_assets"]), 1)


if __name__ == "__main__":
    unittest.main()
