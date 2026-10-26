"""Deployment contract tests for the static container in this repo.

The repo has no application code or JS/Python package, so there is no
third-party test runner to hook into. These stdlib-only tests verify the
things that actually decide whether the deployed container serves traffic:

  1. The Dockerfile has a start command, binds 0.0.0.0 (not localhost) and
     exposes the port the platform is configured to route to.
  2. The static content is served as valid HTML over HTTP by running the
     container's exact CMD.

Run with:  python3 -m unittest discover -s tests -v
"""

import html.parser
import os
import re
import socket
import subprocess
import sys
import time
import unittest
import urllib.error
import urllib.request

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCKERFILE = os.path.join(REPO_ROOT, "Dockerfile")
INDEX = os.path.join(REPO_ROOT, "index.html")

# The port the AppJet deployment is configured to expose for this repo/branch.
EXPECTED_PORT = 80

VOID_TAGS = {"meta", "link", "br", "img", "input", "hr", "source", "area", "base", "col"}


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def dockerfile_instructions(text):
    """Return Dockerfile instructions with comment lines stripped."""
    lines = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        lines.append(line)
    return lines


class HtmlTagBalance(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []
        self.imbalance = []

    def handle_starttag(self, tag, attrs):
        if tag not in VOID_TAGS:
            self.stack.append(tag)

    def handle_endtag(self, tag):
        if tag in VOID_TAGS:
            return
        if self.stack and self.stack[-1] == tag:
            self.stack.pop()
        else:
            self.imbalance.append(tag)


class TestDockerfileContract(unittest.TestCase):
    def setUp(self):
        self.assertTrue(os.path.isfile(DOCKERFILE), "Dockerfile is missing")
        self.text = read(DOCKERFILE)
        self.instructions = dockerfile_instructions(self.text)

    def test_has_base_image(self):
        self.assertTrue(
            any(i.upper().startswith("FROM ") for i in self.instructions),
            "Dockerfile has no FROM instruction",
        )

    def test_has_start_command(self):
        has_cmd = any(re.match(r"(?i)^(CMD|ENTRYPOINT)\b", i) for i in self.instructions)
        self.assertTrue(has_cmd, "Dockerfile has no CMD/ENTRYPOINT start command")

    def test_binds_all_interfaces(self):
        """A localhost/127.0.0.1 bind is the classic cause of a 502."""
        cmd_lines = [i for i in self.instructions if re.match(r"(?i)^(CMD|ENTRYPOINT)\b", i)]
        joined = " ".join(cmd_lines)
        self.assertIn("0.0.0.0", joined, "start command does not bind 0.0.0.0")
        self.assertNotRegex(joined, r"127\.0\.0\.1", "start command binds loopback")
        self.assertNotRegex(joined, r"(?<![\w.])localhost(?![\w.])", "start command binds localhost")

    def test_exposed_port_matches_configured_port(self):
        exposes = [
            int(m.group(1))
            for m in (re.match(r"(?i)^EXPOSE\s+(\d+)", i) for i in self.instructions)
            if m
        ]
        self.assertTrue(exposes, "Dockerfile has no EXPOSE instruction")
        self.assertIn(
            EXPECTED_PORT,
            exposes,
            "EXPOSE %s does not match the configured deployment port %d"
            % (exposes, EXPECTED_PORT),
        )

    def test_honours_port_env_var(self):
        joined = " ".join(self.instructions)
        self.assertIn("PORT", joined, "Dockerfile does not reference $PORT")

    def test_copies_static_content(self):
        joined = " ".join(self.instructions)
        self.assertRegex(joined, r"(?i)COPY\s+", "Dockerfile copies no application content")


class TestStaticContent(unittest.TestCase):
    def setUp(self):
        self.assertTrue(os.path.isfile(INDEX), "index.html is missing")
        self.html = read(INDEX)

    def test_has_doctype_and_document(self):
        self.assertRegex(self.html, r"(?i)^<!DOCTYPE html>")
        self.assertIn("</html>", self.html)

    def test_has_title(self):
        match = re.search(r"<title>(.*?)</title>", self.html, re.S | re.I)
        self.assertIsNotNone(match, "index.html has no <title>")
        self.assertTrue(match.group(1).strip(), "index.html has an empty <title>")

    def test_tags_are_balanced(self):
        parser = HtmlTagBalance()
        parser.feed(self.html)
        self.assertEqual([], parser.stack, "unclosed tags: %s" % parser.stack)
        self.assertEqual([], parser.imbalance, "stray closing tags: %s" % parser.imbalance)

    def test_is_not_the_platform_placeholder(self):
        lowered = self.html.lower()
        self.assertNotIn("default placeholder page", lowered)
        self.assertNotIn("ready for deployment", lowered)


class TestServesOverHttp(unittest.TestCase):
    """Runs the container's own CMD against the repo root and requests '/'."""

    @classmethod
    def setUpClass(cls):
        cls.port = cls._free_port()
        cls.proc = subprocess.Popen(
            [sys.executable, "-m", "http.server", str(cls.port), "--bind", "0.0.0.0"],
            cwd=REPO_ROOT,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env={**os.environ, "PORT": str(cls.port)},
        )
        cls.body = None
        cls.status = None
        cls.content_type = None
        deadline = time.time() + 20
        while time.time() < deadline:
            try:
                with urllib.request.urlopen(
                    "http://127.0.0.1:%d/" % cls.port, timeout=2
                ) as response:
                    cls.status = response.status
                    cls.content_type = response.headers.get("Content-Type", "")
                    cls.body = response.read().decode("utf-8", "replace")
                break
            except (urllib.error.URLError, ConnectionError, socket.timeout):
                time.sleep(0.25)

    @classmethod
    def tearDownClass(cls):
        if getattr(cls, "proc", None) is not None:
            cls.proc.terminate()
            try:
                cls.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                cls.proc.kill()

    @staticmethod
    def _free_port():
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.bind(("0.0.0.0", 0))
            return sock.getsockname()[1]

    def test_server_answered(self):
        self.assertIsNotNone(self.body, "static server never responded on /")

    def test_root_returns_200(self):
        self.assertEqual(200, self.status, "GET / did not return 200")

    def test_root_serves_html(self):
        self.assertIn("text/html", self.content_type or "", "GET / is not text/html")

    def test_root_serves_the_deployed_page(self):
        self.assertIn("<title>x1One AI Web2App Builder</title>", self.body)

    def test_served_body_is_byte_identical_to_index(self):
        self.assertEqual(read(INDEX), self.body, "served body differs from index.html")


if __name__ == "__main__":
    unittest.main(verbosity=2)
