import base64
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "kubernetes/infrastructure/controllers/toolhive/gmail-rest-mcp.yaml"
TOOLHIVE_CONFIG = ROOT / "kubernetes/infrastructure/controllers/toolhive/toolhive-mcp.yaml"


def extract_server(source):
    lines = source.read_text().splitlines()
    start = None
    for index, line in enumerate(lines):
        if line == "  server.py: |":
            start = index + 1
            break
    if start is None:
        raise AssertionError("server.py block not found")

    body = []
    for line in lines[start:]:
        if line == "---":
            break
        if line.startswith("    "):
            body.append(line[4:])
        elif line:
            raise AssertionError(f"unexpected server.py indentation: {line!r}")
        else:
            body.append("")
    return "\n".join(body) + "\n"


def load_server():
    path = Path(tempfile.mkdtemp()) / "server.py"
    path.write_text(extract_server(SOURCE))
    spec = importlib.util.spec_from_file_location("toolhive_google_rest_mcp", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class GoogleRestMcpTest(unittest.TestCase):
    def setUp(self):
        self.server = load_server()
        self.calls = []

        def fake_api(token, base, path, params=None, method="GET", body=None):
            self.calls.append(
                {
                    "token": token,
                    "base": base,
                    "path": path,
                    "params": params,
                    "method": method,
                    "body": body,
                }
            )
            if path.endswith("/modify"):
                return {"id": "msg-1", "labelIds": ["SENT"]}
            if path == "/drafts":
                return {"id": "draft-1", "message": {"id": "msg-1"}}
            if path == "/users/me/calendarList":
                return {"items": [{"id": "primary", "summary": "Personal"}]}
            if path == "/calendars/primary/events":
                return {"id": "event-1", "summary": body["summary"]}
            if path == "/files":
                return {"files": [{"id": "file-1", "name": "Notes"}]}
            return {}

        self.server.api_json = fake_api

    def test_tools_include_write_calendar_and_drive_capabilities(self):
        names = {tool["name"] for tool in self.server.TOOLS}

        self.assertIn("create_draft", names)
        self.assertIn("archive_message", names)
        self.assertIn("list_calendars", names)
        self.assertIn("create_calendar_event", names)
        self.assertIn("list_drive_files", names)

    def test_archive_message_removes_inbox_label(self):
        result = self.server.archive_message("token", {"messageId": "msg-1"})

        self.assertEqual({"id": "msg-1", "labelIds": ["SENT"]}, result)
        self.assertEqual("/messages/msg-1/modify", self.calls[0]["path"])
        self.assertEqual("POST", self.calls[0]["method"])
        self.assertEqual({"removeLabelIds": ["INBOX"]}, self.calls[0]["body"])

    def test_create_draft_builds_raw_rfc822_message(self):
        result = self.server.create_draft(
            "token",
            {
                "to": ["person@example.com"],
                "subject": "Draft subject",
                "body": "Plain body",
            },
        )

        self.assertEqual({"id": "draft-1", "message": {"id": "msg-1"}}, result)
        self.assertEqual("/drafts", self.calls[0]["path"])
        raw = self.calls[0]["body"]["message"]["raw"]
        decoded = base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)).decode()
        self.assertIn("To: person@example.com", decoded)
        self.assertIn("Subject: Draft subject", decoded)
        self.assertIn("Plain body", decoded)

    def test_create_calendar_event_posts_event_body(self):
        result = self.server.create_calendar_event(
            "token",
            {
                "calendarId": "primary",
                "summary": "Planning",
                "start": "2026-06-20T10:00:00-04:00",
                "end": "2026-06-20T10:30:00-04:00",
                "attendees": ["person@example.com"],
            },
        )

        self.assertEqual("event-1", result["id"])
        self.assertEqual(self.server.CALENDAR_API, self.calls[0]["base"])
        self.assertEqual("/calendars/primary/events", self.calls[0]["path"])
        self.assertEqual("POST", self.calls[0]["method"])
        self.assertEqual([{"email": "person@example.com"}], self.calls[0]["body"]["attendees"])

    def test_list_drive_files_uses_drive_api_query(self):
        result = self.server.list_drive_files(
            "token",
            {"query": "name contains 'Notes'", "pageSize": 5},
        )

        self.assertEqual([{"id": "file-1", "name": "Notes"}], result["files"])
        self.assertEqual(self.server.DRIVE_API, self.calls[0]["base"])
        self.assertEqual("/files", self.calls[0]["path"])
        self.assertEqual("name contains 'Notes'", self.calls[0]["params"]["q"])
        self.assertEqual(5, self.calls[0]["params"]["pageSize"])

    def test_toolhive_google_provider_requests_workspace_scopes(self):
        config = TOOLHIVE_CONFIG.read_text()

        self.assertIn("https://www.googleapis.com/auth/gmail.compose", config)
        self.assertIn("https://www.googleapis.com/auth/gmail.modify", config)
        self.assertIn("https://www.googleapis.com/auth/calendar.events", config)
        self.assertIn("https://www.googleapis.com/auth/calendar.freebusy", config)
        self.assertIn("https://www.googleapis.com/auth/calendar.calendarlist.readonly", config)
        self.assertIn("https://www.googleapis.com/auth/drive", config)

    def test_toolhive_uses_google_workspace_backend_names(self):
        config = TOOLHIVE_CONFIG.read_text()

        for name in (
            "google",
            "google-develop-for-good",
            "google-hoa",
            "google-craft-export",
        ):
            self.assertIn(
                f"  name: {name}\n"
                "  namespace: toolhive-system\n"
                "spec:\n"
                "  groupRef:\n"
                "    name: agent-tools",
                config,
            )
            self.assertIn(f"    providerName: {name}\n", config)
            self.assertIn(f"      - name: {name}\n", config)

        for name in (
            "gmail",
            "gmail-develop-for-good",
            "gmail-hoa",
            "gmail-craft-export",
        ):
            self.assertNotIn(f"kind: MCPServerEntry\nmetadata:\n  name: {name}\n", config)

        self.assertNotIn("pending-agent-tools", config)


if __name__ == "__main__":
    unittest.main()
