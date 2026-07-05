import importlib.util
import io
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

        self.assertEqual("application/json", headers["Content-Type"])
        self.assertNotIn("Authorization", headers)
        self.assertNotIn("Connection", headers)
        self.assertNotIn("Host", headers)

    def test_proxy_streams_upstream_chunks_without_buffering(self):
        handler = self.server.Handler.__new__(self.server.Handler)
        handler.command = "POST"
        handler.path = "/mcp?session=abc"
        handler.headers = {"Content-Length": "4", "Authorization": "Bearer client-token"}
        handler.rfile = io.BytesIO(b"body")
        handler.wfile = mock.Mock()
        handler.send_response = mock.Mock()
        handler.send_header = mock.Mock()
        handler.end_headers = mock.Mock()

        read1_sizes = []
        requests = []

        class FakeResponse:
            status = 200
            headers = {"Content-Type": "text/event-stream"}

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read1(self, size=-1):
                read1_sizes.append(size)
                if len(read1_sizes) == 1:
                    return b"data: one\n\n"
                if len(read1_sizes) == 2:
                    return b"data: two\n\n"
                return b""

            def read(self, size=-1):
                raise AssertionError("read() should not be used when read1() is available")

        def fake_urlopen(request, timeout=0):
            requests.append((request, timeout))
            return FakeResponse()

        with mock.patch.dict(
            os.environ,
            {"CRAFT_MCP_UPSTREAM": "https://mcp.example.test/links/token/mcp"},
            clear=True,
        ), mock.patch("urllib.request.urlopen", side_effect=fake_urlopen):
            handler.proxy()

        self.assertEqual(1, len(requests))
        request, timeout = requests[0]
        self.assertEqual("POST", request.method)
        self.assertEqual("https://mcp.example.test/links/token/mcp?session=abc", request.full_url)
        self.assertEqual(b"body", request.data)
        self.assertIsNone(request.get_header("Authorization"))
        self.assertEqual(120, timeout)
        self.assertEqual([65536, 65536, 65536], read1_sizes)
        handler.send_response.assert_called_once_with(200)
        handler.send_header.assert_any_call("Content-Type", "text/event-stream")
        handler.send_header.assert_any_call("Connection", "close")
        handler.end_headers.assert_called_once()
        self.assertEqual([mock.call(b"data: one\n\n"), mock.call(b"data: two\n\n")], handler.wfile.write.call_args_list)
        self.assertEqual([mock.call(), mock.call()], handler.wfile.flush.call_args_list)
        self.assertTrue(handler.close_connection)

    def test_proxy_returns_generic_bad_gateway_on_upstream_failure(self):
        handler = self.server.Handler.__new__(self.server.Handler)
        handler.command = "POST"
        handler.path = "/mcp?session=abc"
        handler.headers = {"Content-Length": "4", "Authorization": "Bearer client-token"}
        handler.rfile = io.BytesIO(b"body")
        handler.wfile = mock.Mock()
        handler.send_response = mock.Mock()
        handler.send_header = mock.Mock()
        handler.end_headers = mock.Mock()

        requests = []

        def fake_urlopen(request, timeout=0):
            requests.append((request, timeout))
            raise ValueError("boom")

        with mock.patch.dict(
            os.environ,
            {"CRAFT_MCP_UPSTREAM": "https://mcp.example.test/links/token/mcp"},
            clear=True,
        ), mock.patch("urllib.request.urlopen", side_effect=fake_urlopen), mock.patch(
            "sys.stderr", new_callable=io.StringIO
        ) as stderr:
            handler.proxy()

        self.assertEqual(1, len(requests))
        self.assertEqual("POST", requests[0][0].method)
        self.assertEqual([mock.call(b"Bad Gateway")], handler.wfile.write.call_args_list)
        self.assertEqual(502, handler.send_response.call_args.args[0])
        self.assertIn("ValueError", stderr.getvalue())
        self.assertNotIn("mcp.example.test", stderr.getvalue())
        self.assertNotIn("client-token", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
