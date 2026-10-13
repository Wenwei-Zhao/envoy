#!/usr/bin/env bash
#
# End-to-end test for the MCP HTTP filter (envoy.filters.http.mcp) at MCP protocol version
# 2026-07-28, with a real MCP client and server, both built on the official MCP Python SDK, which
# the suite pins to version 2.2.0 (MCP_SDK_VERSION below):
#
#   mcp_client.py -> Envoy (envoy.filters.http.mcp -> router) -> mcp_server.py
#
# Builds Envoy unless ENVOY_BIN is set, starts mcp_server.py and then Envoy with envoy.yaml, and
# runs mcp_client.py. Its SDK client sends stateless 2026-07-28 tools/list and tools/call requests
# through Envoy, and its raw HTTP requests check that the MCP filter itself rejects requests that
# break 2026-07-28 rules, and forwards others, such as the legacy handshake methods, to the server.
# Each case checks the response, Envoy's access log, the MCP filter's stats, and whether the request
# reached the server. Prints PASS (exit 0) or FAIL (exit 1), and leaves the logs in RUN_DIR. See
# README.md.
#
# With DEMO=1, it runs the developer demo instead of the regression cases: demo_client.py, with
# mcp_server.py --demo, through the same Envoy config.
#
# compose.yaml runs the same tests in containers instead, with the official Envoy image.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${PYTHON:-python3}"
# The MCP Python SDK version that PYTHON must have, exactly: the suite is pinned to it. The legacy-*
# cases expect this version's server answers, which are not protocol requirements: other versions
# may answer differently. Not taken from the environment. See README.md.
MCP_SDK_VERSION="2.2.0"
# Flags for bazel build and bazel info, such as -c opt. None by default: Envoy's Bazel setup finds
# its toolchain itself, and has had no --config=clang since envoyproxy/envoy#47806.
BAZEL_BUILD_FLAGS="${BAZEL_BUILD_FLAGS:-}"
PORT="${PORT:-10000}"
# The listener whose MCP filter supports protocol versions up to 2025-11-25 only.
CAPPED_PORT="${CAPPED_PORT:-10001}"
ADMIN_PORT="${ADMIN_PORT:-9901}"
BACKEND_PORT="${BACKEND_PORT:-8000}"
LOG_LEVEL="${LOG_LEVEL:-info}"
# Comma-separated names of cases not to run. The client reports each of them as skipped.
SKIP_CASES="${SKIP_CASES:-}"
# 1: run the developer demo (demo_client.py, and the server's demo tools) instead of the cases.
DEMO="${DEMO:-0}"
# How long the MCP server and Envoy each get to become ready.
STARTUP_TIMEOUT_SECONDS=30

if [[ "${DEMO}" != "0" && "${DEMO}" != "1" ]]; then
  echo "ERROR: DEMO must be 0 or 1, not ${DEMO}." >&2
  exit 1
fi
if [[ "${DEMO}" == "1" && -n "${SKIP_CASES}" ]]; then
  echo "ERROR: SKIP_CASES selects regression cases, which DEMO=1 does not run." >&2
  exit 1
fi

if ! command -v curl > /dev/null; then
  echo "ERROR: curl is required." >&2
  exit 1
fi
# Check the SDK first, so that a wrong one does not have to wait for the build. PYTHON must have
# exactly MCP_SDK_VERSION, which must import, and support protocol version 2026-07-28. On failure,
# the check's last line of output says why.
SDK_CHECK='
import importlib.metadata, sys
try:
    version = importlib.metadata.version("mcp")
except importlib.metadata.PackageNotFoundError:
    sys.exit("it has no MCP Python SDK (no mcp package)")
if version != sys.argv[1]:
    sys.exit(f"it has mcp {version}")
try:
    import mcp.client.client, mcp.server.mcpserver, uvicorn
    from mcp.types.version import MODERN_PROTOCOL_VERSIONS
except ImportError as error:
    sys.exit(f"it has mcp {version}, but importing it fails: {error}")
if "2026-07-28" not in MODERN_PROTOCOL_VERSIONS:
    sys.exit(f"it has mcp {version}, which does not support MCP 2026-07-28")
'
if ! sdk_error="$("${PYTHON}" -c "${SDK_CHECK}" "${MCP_SDK_VERSION}" 2>&1)"; then
  echo "ERROR: PYTHON (${PYTHON}) must have the MCP Python SDK at exactly version" \
    "${MCP_SDK_VERSION} (mcp==${MCP_SDK_VERSION}), which this suite is pinned to:" \
    "${sdk_error##*$'\n'}." >&2
  echo "Install that version, for example in a virtualenv with pip install" \
    "'mcp==${MCP_SDK_VERSION}', and set PYTHON to that virtualenv's python3. See README.md" \
    "for why the version is pinned." >&2
  exit 1
fi

if [[ -z "${ENVOY_BIN:-}" ]]; then
  ENVOY_REPO="${ENVOY_REPO:-$(git -C "${HERE}" rev-parse --show-toplevel)}"
  echo "==> Building //source/exe:envoy-static (set ENVOY_BIN to use a prebuilt binary)"
  # shellcheck disable=SC2086 # BAZEL_BUILD_FLAGS is a list of flags.
  (cd "${ENVOY_REPO}" && bazel build ${BAZEL_BUILD_FLAGS} //source/exe:envoy-static)
  # Bazel says where the binary is: the bazel-bin symlink may be missing, or be for other flags.
  # shellcheck disable=SC2086 # BAZEL_BUILD_FLAGS is a list of flags.
  BAZEL_BIN="$(cd "${ENVOY_REPO}" && bazel info ${BAZEL_BUILD_FLAGS} bazel-bin)"
  ENVOY_BIN="${BAZEL_BIN}/source/exe/envoy-static"
fi
if [[ ! -x "${ENVOY_BIN}" ]]; then
  echo "ERROR: ENVOY_BIN is not an executable: ${ENVOY_BIN}" >&2
  exit 1
fi

RUN_DIR="${RUN_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/mcp-e2e.XXXXXX")}"
mkdir -p "${RUN_DIR}"
RUN_DIR="$(cd "${RUN_DIR}" && pwd)"
rm -f "${RUN_DIR}/access.log" "${RUN_DIR}/stats.txt" "${RUN_DIR}/backend_requests.jsonl"

# Something already listening on one of the ports would answer the readiness checks below in place
# of the processes this script starts.
for port in "${BACKEND_PORT}" "${PORT}" "${CAPPED_PORT}" "${ADMIN_PORT}"; do
  if (exec 3<> "/dev/tcp/127.0.0.1/${port}") 2> /dev/null; then
    echo "ERROR: 127.0.0.1:${port} is already in use. Stop whatever listens there, or set" \
      "BACKEND_PORT, PORT, CAPPED_PORT and ADMIN_PORT to free ports." >&2
    exit 1
  fi
done

# The template, and the renderer, that the Docker Compose setup uses too. Here, Envoy and the MCP
# server are both on 127.0.0.1.
sh "${HERE}/render_envoy_config.sh" --template "${HERE}/envoy.yaml" \
  --output "${RUN_DIR}/envoy.yaml" --run-dir "${RUN_DIR}" --listen-address 127.0.0.1 \
  --port "${PORT}" --capped-port "${CAPPED_PORT}" --admin-port "${ADMIN_PORT}" \
  --backend-host 127.0.0.1 --backend-port "${BACKEND_PORT}"

BACKEND_PID=""
ENVOY_PID=""
CLIENT_PID=""

# stop PID: sends TERM, then KILL if the process is still running 5 seconds later, and reaps it.
stop() {
  local pid="$1"
  [[ -n "${pid}" ]] || return 0
  kill -TERM "${pid}" 2> /dev/null || return 0
  for _ in $(seq 1 50); do
    kill -0 "${pid}" 2> /dev/null || break
    sleep 0.1
  done
  kill -KILL "${pid}" 2> /dev/null || true
  wait "${pid}" 2> /dev/null || true
}

# Runs on every exit: success, failure, error, and INT or TERM (whose traps exit).
cleanup() {
  set +e
  stop "${CLIENT_PID}"
  stop "${ENVOY_PID}"
  stop "${BACKEND_PID}"
}
trap cleanup EXIT
trap 'echo "Interrupted. Logs and files: ${RUN_DIR}" >&2; exit 130' INT
trap 'echo "Terminated. Logs and files: ${RUN_DIR}" >&2; exit 143' TERM

# wait_ready NAME PID LOG CURL_ARGS...: waits until `curl CURL_ARGS` succeeds. Fails if the process
# exits first, or if it takes more than STARTUP_TIMEOUT_SECONDS.
wait_ready() {
  local name="$1" pid="$2" log="$3"
  shift 3
  local deadline=$((SECONDS + STARTUP_TIMEOUT_SECONDS))
  until curl -sS -o /dev/null --max-time 1 "$@" 2> /dev/null; do
    if ! kill -0 "${pid}" 2> /dev/null; then
      echo "ERROR: ${name} exited during startup; see ${log}:" >&2
      grep -E '\]\[(critical|error)\]\[' "${log}" >&2 || tail -n 20 "${log}" >&2
      exit 1
    fi
    if ((SECONDS >= deadline)); then
      echo "ERROR: ${name} did not become ready in ${STARTUP_TIMEOUT_SECONDS}s; see ${log}" >&2
      exit 1
    fi
    sleep 0.2
  done
}

SERVER_ARGS=(--port "${BACKEND_PORT}" --request-log "${RUN_DIR}/backend_requests.jsonl")
CLIENT_ARGS=(--port "${PORT}" --capped-port "${CAPPED_PORT}" --admin-port "${ADMIN_PORT}"
  --backend-port "${BACKEND_PORT}" --run-dir "${RUN_DIR}")
if [[ "${DEMO}" == "1" ]]; then
  echo "==> DEMO=1: the developer demo, demo_client.py, with the MCP server's demo tools"
  SERVER_ARGS+=(--demo)
  CLIENT_SCRIPT="demo_client.py"
else
  CLIENT_SCRIPT="mcp_client.py"
  CLIENT_ARGS+=(--skip "${SKIP_CASES}")
fi

echo "==> Starting the MCP server on 127.0.0.1:${BACKEND_PORT}/mcp; files in ${RUN_DIR}"
# The request log is how the client tells which requests reached the server.
"${PYTHON}" -u "${HERE}/mcp_server.py" "${SERVER_ARGS[@]}" > "${RUN_DIR}/backend.log" 2>&1 &
BACKEND_PID=$!
# Any HTTP response will do. / is not the MCP endpoint, so polling it sends no MCP requests.
wait_ready "The MCP server" "${BACKEND_PID}" "${RUN_DIR}/backend.log" \
  "http://127.0.0.1:${BACKEND_PORT}/"

echo "==> Starting Envoy on 127.0.0.1:${PORT} (capped listener on ${CAPPED_PORT}, admin on" \
  "${ADMIN_PORT})"
"${ENVOY_BIN}" -c "${RUN_DIR}/envoy.yaml" -l "${LOG_LEVEL}" --concurrency 1 \
  --disable-hot-restart --file-flush-interval-msec 200 > "${RUN_DIR}/envoy.log" 2>&1 &
ENVOY_PID=$!
wait_ready "Envoy" "${ENVOY_PID}" "${RUN_DIR}/envoy.log" -f "http://127.0.0.1:${ADMIN_PORT}/ready"

echo
CHECKS_FAILED=0
# In the background, so that the INT and TERM traps do not wait for the client to finish.
"${PYTHON}" -u "${HERE}/${CLIENT_SCRIPT}" "${CLIENT_ARGS[@]}" &
CLIENT_PID=$!
wait "${CLIENT_PID}" || CHECKS_FAILED=1
CLIENT_PID=""

# still_running NAME PID LOG: checks that the process did not exit, or crash, during the test.
still_running() {
  if kill -0 "$2" 2> /dev/null; then
    echo "  ok    $1 is still running"
  else
    echo "  FAIL  $1 exited during the test; see $3"
    CHECKS_FAILED=1
  fi
}
echo
echo "Processes"
still_running "Envoy" "${ENVOY_PID}" "${RUN_DIR}/envoy.log"
still_running "The MCP server" "${BACKEND_PID}" "${RUN_DIR}/backend.log"

echo
if [[ "${CHECKS_FAILED}" -ne 0 ]]; then
  echo "FAIL. Logs and files: ${RUN_DIR}"
  exit 1
fi
if [[ -n "${SKIP_CASES}" ]]; then
  echo "PASS, with cases skipped (SKIP_CASES=${SKIP_CASES}). Logs and files: ${RUN_DIR}"
else
  echo "PASS. Logs and files: ${RUN_DIR}"
fi
