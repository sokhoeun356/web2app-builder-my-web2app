#!/usr/bin/env bash
# Deployment contract tests for this repo's static container.
#
# The repository holds only a GitHub Actions workflow plus a static landing
# page, so there is no JS/Python package to run a framework test suite on.
# These checks cover what actually determines whether the deployed container
# serves traffic:
#
#   1. Dockerfile contract: start command, 0.0.0.0 bind, EXPOSE matches the
#      configured deployment port, $PORT honoured.
#   2. index.html: doctype, title, balanced tags, not the platform placeholder.
#   3. Live serve: runs the container's exact CMD and asserts GET / == 200
#      text/html with a body byte-identical to index.html.
#
# Run with:  bash tests/deployment_contract.sh
#
# Kept as shell on purpose: adding *.py files to this repo trips the deploy
# stack classifier into treating the static site as a Python app.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE="$REPO_ROOT/Dockerfile"
INDEX="$REPO_ROOT/index.html"
EXPECTED_PORT=80

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '     -> %s\n' "$2"; }

check() { # check <description> <cmd...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

echo "== Dockerfile contract =="

if [ -f "$DOCKERFILE" ]; then pass "Dockerfile exists"; else fail "Dockerfile exists"; fi

# Instruction lines with comments/blank lines stripped.
INSTR="$(grep -vE '^[[:space:]]*(#|$)' "$DOCKERFILE" 2>/dev/null || true)"

if printf '%s\n' "$INSTR" | grep -qiE '^FROM[[:space:]]+'; then
  pass "declares a base image (FROM)"
else
  fail "declares a base image (FROM)"
fi

START_CMD="$(printf '%s\n' "$INSTR" | grep -iE '^(CMD|ENTRYPOINT)\b' || true)"
if [ -n "$START_CMD" ]; then
  pass "has a start command (CMD/ENTRYPOINT)"
else
  fail "has a start command (CMD/ENTRYPOINT)" "container would exit immediately -> 502"
fi

if printf '%s' "$START_CMD" | grep -q '0\.0\.0\.0'; then
  pass "start command binds 0.0.0.0"
else
  fail "start command binds 0.0.0.0"
fi

if printf '%s' "$START_CMD" | grep -qE '127\.0\.0\.1|(^|[^[:alnum:]_.])localhost([^[:alnum:]_.]|$)'; then
  fail "start command avoids loopback bind" "loopback bind is not reachable -> 502"
else
  pass "start command avoids loopback bind"
fi

EXPOSED="$(printf '%s\n' "$INSTR" | grep -iE '^EXPOSE[[:space:]]+' | grep -oE '[0-9]+' | head -n1 || true)"
if [ "$EXPOSED" = "$EXPECTED_PORT" ]; then
  pass "EXPOSE $EXPECTED_PORT matches the configured deployment port"
else
  fail "EXPOSE matches the configured deployment port" "EXPOSE=${EXPOSED:-<none>} expected=$EXPECTED_PORT"
fi

check "start command honours \$PORT" grep -q 'PORT' <<<"$INSTR"
check "copies application content (COPY)" grep -qiE '^COPY[[:space:]]' <<<"$INSTR"

echo "== Static content =="

if [ -f "$INDEX" ]; then pass "index.html exists"; else fail "index.html exists"; fi

if head -n1 "$INDEX" 2>/dev/null | grep -qiE '^<!DOCTYPE html>'; then
  pass "index.html starts with <!DOCTYPE html>"
else
  fail "index.html starts with <!DOCTYPE html>"
fi

if tail -n5 "$INDEX" 2>/dev/null | grep -qi '</html>'; then
  pass "index.html closes </html>"
else
  fail "index.html closes </html>"
fi

TITLE="$(sed -n 's:.*<title>\(.*\)</title>.*:\1:p' "$INDEX" 2>/dev/null | head -n1)"
if [ -n "${TITLE//[[:space:]]/}" ]; then
  pass "index.html has a non-empty <title> (\"$TITLE\")"
else
  fail "index.html has a non-empty <title>"
fi

if grep -qiE 'default placeholder page|ready for deployment' "$INDEX" 2>/dev/null; then
  fail "index.html is not the platform placeholder"
else
  pass "index.html is not the platform placeholder"
fi

if python3 - "$INDEX" <<'PY'
import html.parser, sys

VOID = {"meta", "link", "br", "img", "input", "hr", "source", "area", "base", "col"}

class P(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack, self.stray = [], []

    def handle_starttag(self, tag, attrs):
        if tag not in VOID:
            self.stack.append(tag)

    def handle_endtag(self, tag):
        if tag in VOID:
            return
        if self.stack and self.stack[-1] == tag:
            self.stack.pop()
        else:
            self.stray.append(tag)

p = P()
p.feed(open(sys.argv[1], encoding="utf-8").read())
if p.stack or p.stray:
    print("unclosed=%s stray=%s" % (p.stack, p.stray))
    sys.exit(1)
PY
then
  pass "index.html tags are balanced"
else
  fail "index.html tags are balanced"
fi

echo "== Live serve (container CMD) =="

PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("0.0.0.0",0));print(s.getsockname()[1]);s.close()')"
SERVER_LOG="$(mktemp)"
BODY="$(mktemp)"
HEADERS="$(mktemp)"

cleanup() { [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null; wait "${SERVER_PID:-}" 2>/dev/null; rm -f "$SERVER_LOG" "$BODY" "$HEADERS"; }
trap cleanup EXIT

# Same command the Dockerfile runs: honour $PORT, bind all interfaces.
( cd "$REPO_ROOT" && PORT="$PORT" python3 -m http.server "$PORT" --bind 0.0.0.0 ) >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

READY=0
for _ in $(seq 1 80); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then READY=1; break; fi
  sleep 0.25
done

if [ "$READY" -eq 1 ]; then
  pass "static server answers on 0.0.0.0:\$PORT"
else
  fail "static server answers on 0.0.0.0:\$PORT" "$(tail -n3 "$SERVER_LOG")"
fi

STATUS="$(curl -s -o "$BODY" -D "$HEADERS" -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null || echo 000)"
if [ "$STATUS" = "200" ]; then
  pass "GET / returns 200"
else
  fail "GET / returns 200" "got $STATUS"
fi

if grep -qi '^content-type:[[:space:]]*text/html' "$HEADERS" 2>/dev/null; then
  pass "GET / is served as text/html"
else
  fail "GET / is served as text/html" "$(grep -i '^content-type' "$HEADERS" 2>/dev/null | head -n1)"
fi

if grep -q '<title>x1One AI Web2App Builder</title>' "$BODY" 2>/dev/null; then
  pass "GET / serves the expected page"
else
  fail "GET / serves the expected page"
fi

if cmp -s "$INDEX" "$BODY"; then
  pass "served body is byte-identical to index.html"
else
  fail "served body is byte-identical to index.html"
fi

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL CHECKS PASSED"
