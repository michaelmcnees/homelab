import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "kubernetes/infrastructure/controllers/toolhive/craft-mcp-proxy.yaml"


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
    spec = importlib.util.spec_from_file_location("toolhive_craft_mcp_proxy", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class CraftMcpProxyTest(unittest.TestCase):
    def setUp(self):
        self.server = load_server()

    def test_upstream_url_requires_secret_env(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(RuntimeError, "CRAFT_MCP_UPSTREAM"):
                self.server.upstream_url("/mcp")

    def test_upstream_url_preserves_request_path_and_query(self):
        with mock.patch.dict(
            os.environ,
            {"CRAFT_MCP_UPSTREAM": "https://mcp.example.test/links/token/mcp"},
            clear=True,
        ):
            result = self.server.upstream_url("/mcp?session=abc")

        self.assertEqual("https://mcp.example.test/links/token/mcp?session=abc", result)

    def test_hop_by_hop_headers_are_not_forwarded(self):
        headers = self.server.forward_headers(
            {
                "Authorization": "Bearer client-token",
                "Connection": "keep-alive",
                "Host": "craft-mcp-proxy",
                "Content-Type": "application/json",
            }
        )

        self.assertEqual("Bearer client-token", headers["Authorization"])
        self.assertEqual("application/json", headers["Content-Type"])
        self.assertNotIn("Connection", headers)
        self.assertNotIn("Host", headers)


if __name__ == "__main__":
    unittest.main()
