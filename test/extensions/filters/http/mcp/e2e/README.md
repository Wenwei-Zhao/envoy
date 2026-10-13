# MCP filter end-to-end test: MCP 2026-07-28 through Envoy, with a real MCP client and server

This test sends MCP protocol version 2026-07-28 traffic through Envoy's MCP filter
(`envoy.filters.http.mcp`). The client and the server are built on the official MCP Python SDK, the
[`mcp`](https://pypi.org/project/mcp/) package, pinned to version 2.2.0, and use its Streamable HTTP
transport:

```
mcp_client.py ──▶ Envoy: envoy.filters.http.mcp ─▶ router ──▶ mcp_server.py
                  127.0.0.1:10000, the main listener          127.0.0.1:8000/mcp
                  127.0.0.1:10001, capped at 2025-11-25
```

The server has one tool, `get_weather(city)`, whose result is fixed. The client runs two kinds of
cases:
- **With the SDK, pinned to 2026-07-28:** through the main listener, it lists the tools and calls
  `get_weather`, as stateless requests that must reach the server and return its results. Through
  the capped listener, whose MCP filter supports protocol versions up to 2025-11-25 only, it lists
  the tools, and the filter must reject the request itself.
- **With raw HTTP, for requests that the SDK does not send:** each request breaks one 2026-07-28
  rule, and the MCP filter must answer it itself, without forwarding it. One more, valid, request
  has a base64-encoded `Mcp-Name` header, and must reach the server. Two more send the legacy
  handshake methods, `initialize` and `notifications/initialized`, at 2026-07-28: the MCP filter
  forwards them, and the server answers them.

For each case, the client checks the response, Envoy's access log entry (with the MCP filter's
dynamic metadata), the MCP filter's counters, and whether the request reached the server, in the
server's request log.

`DEMO=1` runs a [developer demo](#developer-demo-demo1) instead: a simulated service-operations
scenario with more tools, which also shows `server/discover`, cache hints and a multi round-trip
request through Envoy.

Both run on the host with `run.sh`, or in containers with Docker Compose and the official Envoy
image, with nothing to install but Docker: see [Run with Docker Compose](#run-with-docker-compose).

## Prerequisites

For [Docker Compose](#run-with-docker-compose), only Docker, with Compose v2. For `run.sh`:
- Linux, `bash` and `curl`.
- Python 3.10 or newer, with the MCP Python SDK at exactly version 2.2.0, `mcp==2.2.0`, which the
  suite is pinned to: `run.sh` runs both the client and the server with that SDK. Before it builds
  or starts anything, `run.sh` checks the version, and stops with an error if `PYTHON` has no SDK,
  or any other version, including other 2.x versions that support 2026-07-28. See
  [The pinned SDK version](#the-pinned-sdk-version) for why. Install it in a virtualenv:

  ```sh
  python3 -m venv /tmp/mcp-e2e-venv
  /tmp/mcp-e2e-venv/bin/pip install 'mcp==2.2.0'
  ```

  If `python3 -m venv` fails because `ensurepip` is not available, install your distribution's
  `python3-venv` package, or make the virtualenv with [uv](https://docs.astral.sh/uv/):

  ```sh
  uv venv /tmp/mcp-e2e-venv
  uv pip install --python /tmp/mcp-e2e-venv/bin/python3 'mcp==2.2.0'
  ```
- An Envoy whose MCP filter has the merged 2026-07-28 support that the cases test: protocol version
  enforcement (envoyproxy/envoy#47280), the `clientCapabilities` check (envoyproxy/envoy#47915),
  and the parser fix that check relies on (envoyproxy/envoy#47862). That is Envoy's `main` branch
  since #47915, the last of them, was merged.
- To build Envoy: Bazel and Envoy's build dependencies, as in
  [`bazel/README.md`](../../../../../../bazel/README.md). Not needed if you set `ENVOY_BIN`.
- Free ports 8000, 9901, 10000 and 10001 on 127.0.0.1, or other ports in `BACKEND_PORT`,
  `ADMIN_PORT`, `PORT` and `CAPPED_PORT`.

## Run

From the root of the Envoy checkout:

```sh
# Builds //source/exe:envoy-static, then runs the test.
PYTHON=/tmp/mcp-e2e-venv/bin/python3 test/extensions/filters/http/mcp/e2e/run.sh
# Runs the test with an Envoy binary you already have.
PYTHON=/tmp/mcp-e2e-venv/bin/python3 ENVOY_BIN=/path/to/envoy-static \
  test/extensions/filters/http/mcp/e2e/run.sh
```

The script:
1. checks for `curl`, and that `PYTHON` has the MCP Python SDK at exactly the pinned version, 2.2.0;
2. unless `ENVOY_BIN` is set, runs `bazel build ${BAZEL_BUILD_FLAGS} //source/exe:envoy-static`,
   and asks `bazel info` where the binary is;
3. renders `envoy.yaml` with `render_envoy_config.sh`, with everything on 127.0.0.1, into `RUN_DIR`;
4. starts `mcp_server.py` with a request log, and waits until it answers HTTP requests;
5. starts Envoy, and waits until the admin endpoint's `/ready` returns 200;
6. runs `mcp_client.py`, which prints each case, and each of its checks as `ok` or `FAIL`;
7. checks that the server and Envoy are still running;
8. prints `PASS` (exit 0) or `FAIL` (exit 1), and the path of `RUN_DIR`.

The server and Envoy each get 30 seconds to start. Each SDK case gets 30 seconds, and each raw
request 10 seconds. Once Envoy is built, a run takes a few seconds. On every exit, including a
failure and Ctrl-C, the script stops the client, Envoy and the server: TERM, then KILL if one is
still running 5 seconds later.

| Variable | Default | |
|---|---|---|
| `PYTHON` | `python3` | The Python that runs the server and the client. It needs the SDK |
| `ENVOY_BIN` | unset | Use this Envoy binary instead of building one |
| `BAZEL_BUILD_FLAGS` | none | Flags for the build, and for `bazel info`, such as `-c opt` |
| `ENVOY_REPO` | the checkout this directory is in | Where to build Envoy |
| `PORT`, `CAPPED_PORT` | `10000`, `10001` | Envoy's main and capped listener ports |
| `ADMIN_PORT` | `9901` | Envoy's admin port |
| `BACKEND_PORT` | `8000` | The MCP server's port |
| `LOG_LEVEL` | `info` | Envoy's log level |
| `SKIP_CASES` | unset | Comma-separated names of cases not to run. Each is reported as `SKIP`, and the final line says that cases were skipped |
| `DEMO` | `0` | `1` runs the [developer demo](#developer-demo-demo1) instead of the regression cases |
| `RUN_DIR` | a new temp directory | Where the run's files go |

## Run with Docker Compose

[`compose.yaml`](compose.yaml) runs the same tests in three containers, with the official Envoy
image. It needs only Docker, with Compose v2: no virtualenv, no MCP SDK and no Envoy build. From
this directory:

```sh
# The 17 regression cases.
docker compose up --build --abort-on-container-exit --exit-code-from mcp-client
# The developer demo.
DEMO=1 docker compose up --build --abort-on-container-exit --exit-code-from mcp-client
# Afterwards: remove the containers, their network, and the run volume.
docker compose down -v
```

`docker compose up` returns the client's exit code: 0 for `PASS`, 1 for `FAIL`. Its
`--abort-on-container-exit` stops the three containers once the client exits, or once any of them
exits first, which fails the run. The first run also pulls the Envoy image and builds the Python
image. Add `--attach mcp-client` to see only the client's output. From the root of the checkout,
add `-f test/extensions/filters/http/mcp/e2e/compose.yaml` after `docker compose`.

| Service | Image | What it does |
|---|---|---|
| `mcp-server` | `envoy-mcp-e2e-python:mcp-2.2.0`, built from [`docker/Dockerfile`](docker/Dockerfile): `python:3.13-slim`, pinned by digest, and [`docker/requirements.txt`](docker/requirements.txt), `mcp==2.2.0` with every dependency pinned by hash | [`docker/server_entrypoint.sh`](docker/server_entrypoint.sh): clears the run directory, then runs `mcp_server.py --host 0.0.0.0`, with `--demo` for `DEMO=1`. It is healthy once it accepts connections. |
| `envoy` | `envoyproxy/envoy:dev-158e9b65ca983e1d37b6ec078ab017b5bab61f6e@sha256:344a56243e7eb8676ec4346ac46a20acb575f677257249099a50b65950d3b5e4` | Starts once `mcp-server` is healthy. [`docker/envoy_entrypoint.sh`](docker/envoy_entrypoint.sh) renders `envoy.yaml` with `render_envoy_config.sh`, with the listeners and the admin endpoint on 0.0.0.0, and the cluster at `mcp-server:8000`. Then it runs Envoy with `run.sh`'s flags. |
| `mcp-client` | The same as `mcp-server` | [`docker/client_entrypoint.py`](docker/client_entrypoint.py) does what `run.sh` does once the server and Envoy are up:<br>1. waits for Envoy's `/ready`, and prints Envoy's version;<br>2. runs `mcp_client.py`, or `demo_client.py`, with `--envoy-host envoy --backend-host mcp-server`;<br>3. checks that Envoy and the server are still up;<br>4. prints `PASS` or `FAIL`. |

The client reaches Envoy at `envoy:10000`, `10001` and the admin port `9901`, and Envoy reaches the
server at `mcp-server:8000`: service names on the project's network. No port is published on the
host, so the setup does not conflict with `run.sh`.

**The Envoy image.** The default image is the official development image of Envoy's main commit
`158e9b65ca`.
- It has the MCP filter's 2026-07-28 support, including envoyproxy/envoy#47280, #47915 and #47862.
  No stable release image has them yet: `v1.39.x` rejects `envoy.yaml`.
- It was verified by its binary's revision (`envoy --version`, and the ELF build ID, of the amd64
  and arm64 binaries), and with the 17 regression cases, run against its binary on the host.
- It is pinned by digest.

`ENVOY_IMAGE` replaces the default image, for example `ENVOY_IMAGE=envoyproxy/envoy:dev` for main's
latest image. The client then warns that Envoy is not the verified revision. The image needs
`/bin/sh`, `sed` and its own `/docker-entrypoint.sh`, as the Ubuntu-based variants have, and the
distroless ones do not.

To move the pin:
1. Choose an image whose Envoy revision contains the MCP changes that the suite tests.
2. Check that revision in its binary.
3. Run both modes with `ENVOY_IMAGE`.
4. Update the digest and `VERIFIED_ENVOY_REVISION` in `compose.yaml`.

**Logs and results.** The three services share a run directory, `/e2e-run`: a Docker volume, or a
host directory with `RUN_DIR` set. It has:
- `access.log`, `backend_requests.jsonl`, `envoy.yaml` (as rendered) and `stats.txt`, as `run.sh`'s
  `RUN_DIR` has
- `server_info.json`: Envoy's admin `/server_info`, with its version and the extensions it has
- `client_output.txt`: the client's output

Envoy's own log and the server's, `envoy.log` and `backend.log` for `run.sh`, are in
`docker compose logs`, until `docker compose down`. The containers write the files as root: on a
Linux host, a `RUN_DIR`'s files belong to root, and `docker cp` copies them as yours.

```sh
docker compose logs envoy  # or mcp-server
# Before docker compose down -v: copy the run directory out of its volume.
docker cp "$(docker compose ps -aq mcp-client)":/e2e-run/. /tmp/mcp-e2e-run
# Or keep it in a host directory in the first place.
RUN_DIR=/tmp/mcp-e2e-run \
  docker compose up --build --abort-on-container-exit --exit-code-from mcp-client
```

| Variable | Default | |
|---|---|---|
| `ENVOY_IMAGE` | the verified, pinned image | The Envoy image |
| `DEMO` | `0` | `1` runs the developer demo |
| `SKIP_CASES` | unset | As for `run.sh` |
| `LOG_LEVEL` | `info` | Envoy's log level |
| `RUN_DIR` | the `run` volume | A host directory for the run directory: an absolute path, or a relative one that starts with `./`, from this directory |

How the containers differ from `run.sh`. None of these changes a check:
- **Upstream host:** Envoy logs the server's container address as the upstream host of the
  requests that it forwards. `mcp_client.py` compares it with the address that `mcp-server`
  resolves to, as it compares it with 127.0.0.1 for `run.sh` (`--backend-host`).
- **Host header:** the server listens on 0.0.0.0. For that host, the SDK turns off its
  localhost-only DNS rebinding protection, and so accepts the Host header that Envoy forwards,
  `envoy:10000`.
- **Server readiness:** the healthcheck only opens a connection to the server, so
  `backend_requests.jsonl` has no `GET /` entry, which `run.sh`'s readiness check leaves.
- **Envoy's user:** Envoy runs as root in its container (`ENVOY_UID=0`), so that it can write its
  access log into the shared run directory.
- **SELinux:** on hosts that enforce SELinux, such as Fedora, the containers may need the `z`
  option to read the bind-mounted directories: `.:/e2e:ro,z` in `compose.yaml`, and the same for
  a `RUN_DIR`.

## Files

| File | |
|---|---|
| [`run.sh`](run.sh) | Builds Envoy, starts the server and Envoy, runs the client, cleans up. |
| [`envoy.yaml`](envoy.yaml) | The Envoy config: a template, for `run.sh` and Docker Compose. |
| [`render_envoy_config.sh`](render_envoy_config.sh) | Fills in `envoy.yaml`'s placeholders, for `run.sh` and the `envoy` service. |
| [`mcp_server.py`](mcp_server.py) | The MCP server: `get_weather(city)` over Streamable HTTP, with a request log. With `--demo`, also the demo's tools. |
| [`mcp_client.py`](mcp_client.py) | The MCP client, the raw HTTP requests, and the checks: the regression suite. |
| [`demo_client.py`](demo_client.py) | The developer demo (`DEMO=1`). Not part of the regression suite. |
| [`demo_tools.py`](demo_tools.py) | The demo's simulated service-operations tools, for `mcp_server.py --demo`. |
| [`compose.yaml`](compose.yaml) | The Docker Compose setup: `mcp-client`, `envoy` and `mcp-server`. |
| [`docker/`](docker) | The Python image of `mcp-client` and `mcp-server` (`Dockerfile`, `requirements.in`, `requirements.txt`), and the services' entrypoints. |

## Protocol version 2026-07-28 with the SDK

**How the client selects 2026-07-28.** `mcp_client.py` makes its client with
`Client(url, mode="2026-07-28")`. The SDK's `mode` is `"legacy"`, `"auto"` (the default), or one of
the versions in `MODERN_PROTOCOL_VERSIONS`. With a version, the client adopts that version at once:
it sends no `initialize` handshake and no `server/discover` probe, and does not fall back to the
handshake when a request fails. `"auto"` would probe `server/discover` first, and could fall back to
the 2025-11-25 handshake, which is what `"legacy"` does. The test uses neither. It checks that the
client uses 2026-07-28, and, in the access log, that Envoy saw no requests from it other than its
`tools/list` and `tools/call`. The client also has no response cache (`cache=None`), so that each
call goes through Envoy to the server.

**What the SDK sends at 2026-07-28.** Each request is a stateless `POST`, with no `Mcp-Session-Id`,
and there is no GET stream and no `DELETE`. Each request has:
- the headers `MCP-Protocol-Version: 2026-07-28` and `Mcp-Method`, and for `tools/call`
  `Mcp-Name`, the tool. The SDK base64-encodes a header value (`=?base64?...?=`) only when it needs
  to, so the test sends a base64-encoded `Mcp-Name` itself, with raw HTTP;
- `params._meta`, with `io.modelcontextprotocol/protocolVersion`,
  `io.modelcontextprotocol/clientInfo` and `io.modelcontextprotocol/clientCapabilities`. The test's
  client registers no callbacks, such as for sampling, elicitation or roots, so its capabilities
  are an empty object, `{}`. The raw cases send the same `params._meta`, unless they break it.

**How the server supports it.** `mcp_server.py` serves `MCPServer.streamable_http_app()` with
uvicorn, the same app as `server.run(transport="streamable-http")`. It needs no configuration for
2026-07-28: the SDK answers each request whose `MCP-Protocol-Version` header is 2026-07-28 on its
own, statelessly, once it has checked the request's headers and `params._meta` against the body.

### The pinned SDK version

The suite is pinned to `mcp` 2.2.0: `run.sh` stops with an error for any other version, and the
Docker Compose image installs exactly that one. The client and the server are both that SDK, and
the expectations rely on what it does, not only on what the MCP protocol requires. In particular:
- **The server's answers to the legacy handshake.** The 404 and the 202 that `legacy-initialize`
  and `legacy-initialized-notification` expect are the answers of `mcp` 2.2.0's server, not
  protocol requirements. The spec allows other answers to both, and other versions of the SDK need
  not give the same ones: `mcp` 2.0.0 refuses the notification, with 400 and -32600. See
  [The legacy handshake at 2026-07-28](#the-legacy-handshake-at-2026-07-28).
- **The client's requests.** The SDK cases rely on 2.2.0's client: on its API, such as
  `Client(mode=...)`, and on exactly the requests that it sends, such as their `params._meta`.

To move the suite to another SDK version, change it everywhere it is pinned: `MCP_SDK_VERSION` in
`run.sh` and in `docker/client_entrypoint.py`, `docker/requirements.in`, from which you regenerate
`docker/requirements.txt` with the command in its header, and the Python image's tag in
`compose.yaml`. Then check what that version's server answers, notably to the `legacy-*` cases, and
what its client sends, and update the expectations in `mcp_client.py` and this README to match.

## Cases

Each check prints `ok` or `FAIL`, and any `FAIL` fails the test. The SDK cases:

| Case | Request | Expected |
|---|---|---|
| `sdk-stateless-tools` | `tools/list`, then `tools/call` of `get_weather` with `{"city": "Paris"}`, through the main listener | `tools/list` returns `get_weather`, and `tools/call` returns one text block, `Paris: sunny, 22C`, and no error. Envoy logged these two `POST`s and no other request, each with the 2026-07-28 headers and no `Mcp-Session-Id`, forwarded to the server, which answered 200, with no response flags. The MCP filter's metadata has `status: mcp_ok`, `jsonrpc: 2.0`, an `id`, the method, `params.name` for `tools/call`, and exactly the SDK's `params._meta`: the protocol version, the client info, and the client capabilities, `{}`. The server received both, and created no session. No MCP filter counter changed. |
| `sdk-unsupported-version` | `tools/list` through the capped listener | `MCPError` -32022, `Unsupported MCP protocol version: 2026-07-28`, with data `{"supported": ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"], "requested": "2026-07-28"}`. Envoy logged that `POST` and no other request, so the client did not fall back to the handshake. Envoy answered 400 itself, and the server received nothing. No MCP filter counter changed. |

The raw HTTP cases, all through the main listener. Each sends what the SDK sends, but for the one
thing in the Request column. Each carries an `X-E2E-Case` header with its name, which is how the
client finds it in Envoy's access log and the server's request log.

| Case | Request | Expected response | Counter |
|---|---|---|---|
| `base64-mcp-name` | `tools/call` with `Mcp-Name: =?base64?Z2V0X3dlYXRoZXI=?=` | 200 from the server, with the tool result | |
| `missing-mcp-method` | `tools/list` without `Mcp-Method` | 400, -32020 `Missing required Mcp-Method header`, `id: null` | `header_mismatch` +1 |
| `missing-mcp-name` | `tools/call` without `Mcp-Name` | 400, -32020 `Missing required Mcp-Name header`, `id: null` | `header_mismatch` +1 |
| `invalid-base64-mcp-name` | `tools/call` with `Mcp-Name: =?base64?%%%?=` | 400, -32020 `Invalid Base64-encoded Mcp-Name header`, `id: null` | `header_mismatch` +1 |
| `mcp-method-mismatch` | `Mcp-Method: tools/list` on a `tools/call` body | 400, -32020 `MCP header attributes do not match request body`, the request's `id` | `header_mismatch` +1 |
| `mcp-name-mismatch` | `Mcp-Name: get_weather` on a `tools/call` of `get_forecast` | 400, -32020 `MCP header attributes do not match request body`, the request's `id` | `header_mismatch` +1 |
| `protocol-version-mismatch` | `params._meta` protocol version 2025-11-25 | 400, -32020 `MCP-Protocol-Version header does not match request body`, the request's `id` | `header_mismatch` +1 |
| `unknown-protocol-version` | `MCP-Protocol-Version: 2099-01-01` | 400, -32022 `Unsupported MCP protocol version: 2099-01-01`, `id: null`, with the five versions the filter knows as `supported` | |
| `missing-client-capabilities` | `params._meta` without `io.modelcontextprotocol/clientCapabilities` | 400, -32602 `Missing required params._meta field: io.modelcontextprotocol/clientCapabilities`, the request's `id` | |
| `missing-meta` | `tools/list` with no `params`, so no `params._meta` | 400, -32602 `Missing required params._meta field: io.modelcontextprotocol/clientCapabilities`, the request's `id` | |
| `missing-client-capabilities-id-last` | As `missing-client-capabilities`, but with the `id` after `params` | 400, -32602 `Missing required params._meta field: io.modelcontextprotocol/clientCapabilities`, the request's `id` | |
| `session-delete` | `DELETE` with an `Mcp-Session-Id` | 405, text `MCP DELETE is not supported for protocol version 2026-07-28`, `Allow: POST` | |
| `sse-get` | `GET` with `Accept: text/event-stream` | 405, text `MCP GET with SSE is not supported for protocol version 2026-07-28`, `Allow: POST` | |
| `legacy-initialize` | `initialize`, the legacy handshake, with its `protocolVersion`, `capabilities` and `clientInfo` params | 404 from the server, -32601 `Method not found`, `data: "initialize"`, the request's `id`: the pinned SDK's answer, not a protocol requirement | |
| `legacy-initialized-notification` | `notifications/initialized`, which ends the legacy handshake: a notification, with no `id` | 202 from the server, with no body: the pinned SDK's answer, not a protocol requirement | |

The JSON-RPC errors come as `application/json`. Besides the response, each raw case checks:
- **The MCP filter's counters:** `requests_rejected`, `invalid_json`, `body_too_large`,
  `duplicate_keys_rejected` and `header_mismatch`, under `http.ingress_http.mcp.`, changed exactly
  as in the Counter column, and the others not at all.
- **Envoy's access log:** for the cases that reach the server, `base64-mcp-name` and the two
  `legacy-*` cases, the request went to the server, Envoy passed on the server's status
  (`response_code_details: via_upstream`), and there are no response flags. The MCP filter's
  metadata has `status: mcp_ok`, `is_mcp_request: true`, and attributes that it parsed from the
  body: for `base64-mcp-name`, the method and `params.name`; for `legacy-initialize`, `jsonrpc`, the
  `id`, the method, `params.protocolVersion`, `params.clientInfo.name` and `params._meta`; for
  `legacy-initialized-notification`, `jsonrpc`, the method and `params._meta`, and no `id`. For the
  other cases, Envoy answered with the expected status, with no upstream host, and the metadata has
  `status: mcp_not_jsonrpc` and `is_mcp_request: false`. The 405s have no metadata.
- **The server's request log:** each case that reaches the server reached it once, with the same
  MCP headers, and the server answered with the expected status. No other raw case reached it.

The server would reject most of these requests too, but with its own error messages. The exact
message, the missing upstream host and the server's request log show that Envoy rejected each one.
The other way round, the 404 of `legacy-initialize` is the server's, not an MCP filter rejection:
the server logged the request and its 404, and Envoy logged the upstream host and `via_upstream`.
A response that Envoy makes itself, such as an MCP filter rejection, has other response code
details.

### The merged behavior that the cases test

The cases test the MCP filter as reviewed and merged, within the scope of each change. The filter
makes these checks in `traffic_mode: REJECT_NO_MCP`, which `envoy.yaml` sets.

| Change | What the MCP filter does | Cases |
|---|---|---|
| Protocol version enforcement, envoyproxy/envoy#47280 | Answers a protocol version that `max_supported_protocol_version` does not allow, newer or unknown, with -32022, before it reads the body. At 2026-07-28: requires `Mcp-Method`, and `Mcp-Name` for a method that has a name attribute, such as `tools/call`; decodes a base64-encoded `Mcp-Name`; answers a missing, invalid or mismatched header, or a mismatched protocol version in `params._meta`, with -32020; and answers the GET stream and `DELETE`, which 2026-07-28 drops, with 405 | `sdk-unsupported-version`, `unknown-protocol-version`, `protocol-version-mismatch`, `missing-mcp-method`, `missing-mcp-name`, `invalid-base64-mcp-name`, `mcp-method-mismatch`, `mcp-name-mismatch`, `base64-mcp-name`, `session-delete`, `sse-get` |
| Required client capabilities, envoyproxy/envoy#47915 | Answers a 2026-07-28 request, but not a notification, whose `params._meta` does not have the key `io.modelcontextprotocol/clientCapabilities`, with -32602 | `missing-client-capabilities`, `missing-meta`, `missing-client-capabilities-id-last`; and `sdk-stateless-tools`, whose client capabilities are `{}` |
| Parser path tracking, envoyproxy/envoy#47862 | Keeps its place in the body after an object whose key has dots, such as the client info in `params._meta`, and so finds the fields after it, such as an `id` after `params` | `missing-client-capabilities-id-last` |
| None: the filter has no rule for the legacy handshake | Forwards `initialize` and `notifications/initialized` at 2026-07-28, as it does any request whose headers match its body and that has client capabilities, which a notification does not need | `legacy-initialize`, `legacy-initialized-notification` |

**Client capabilities.** The check is envoyproxy/envoy#47915's: that the key is there. It does not
check the key's value, or the capabilities that an operation needs (-32021,
`MissingRequiredClientCapabilityError`), and notifications are exempt. `missing-meta` checks that
a request with no `params._meta` at all fails it too. `missing-client-capabilities-id-last` is a
regression test for envoyproxy/envoy#47862: before it, the filter's parser lost its place in the
body after the client info, and so lost an `id` that came after `params`. With no `id`, the request
looked like a notification, and the filter forwarded it.

**Protocol version.** The `params._meta` check of envoyproxy/envoy#47280 is a consistency check:
the filter compares a protocol version that is there with the `MCP-Protocol-Version` header, and
answers one that differs, or that is not a string, with -32020. A request whose `params._meta` has
client capabilities but no protocol version passes it.

### The legacy handshake at 2026-07-28

`legacy-initialize` and `legacy-initialized-notification` check that the MCP filter forwards the
legacy handshake at 2026-07-28, and that Envoy passes on what the server answers. The forwarding is
the MCP filter's behavior. The responses that the cases expect, 404 and 202, are the pinned SDK's
answers, not protocol requirements:
- **Spec:** 2026-07-28 removes the `initialize` handshake, but does not require an intermediary to
  reject its messages, and does not fix a server's answer to them. Its general rules leave room: a
  server must answer a method that it does not implement with 404 and -32601, and one that supports
  only modern versions should name the versions that it supports in any error to `initialize`; but
  a server that supports both eras may answer `initialize` with the legacy handshake. A server may
  accept a notification (202, with no body) or refuse it (an HTTP error status).
- **MCP filter:** it has no rule for these methods. It forwards them, as it does any 2026-07-28
  request whose headers match its body and whose `params._meta` has client capabilities, which a
  notification does not need.
- **MCP JSON-REST bridge:** for a 2026-07-28 request, it answers both methods itself, with -32601
  (envoyproxy/envoy#47619, re-landed as envoyproxy/envoy#47817). That is the bridge's behavior, for
  the E2E test with a REST backend to check; this test has no bridge.
- **Server, `mcp` 2.2.0:** it serves both eras, but picks one from the `MCP-Protocol-Version`
  header alone, and has no `initialize` at 2026-07-28. So it answers `initialize` as a method that
  it does not implement: 404 and -32601, with its own message, `Method not found`, and the method as
  `data`. It accepts any notification at 2026-07-28, with 202 and no body. Another server, or
  another version of the SDK, may answer differently and still follow the spec: `mcp` 2.0.0 refuses
  the notification with 400, -32600 `Body must be a single JSON-RPC request object`. That is why
  the suite is pinned to 2.2.0; see [The pinned SDK version](#the-pinned-sdk-version).

## Developer demo (DEMO=1)

`DEMO=1` runs [`demo_client.py`](demo_client.py) in place of the regression cases: a walk-through of
MCP 2026-07-28 through Envoy, for developers. It uses the same Envoy config, SDK, process management
and logs. It is not part of the regression suite, and does not change it: without `DEMO=1`,
`run.sh` and the server behave exactly as before.

```sh
DEMO=1 PYTHON=/tmp/mcp-e2e-venv/bin/python3 ENVOY_BIN=/path/to/envoy-static \
  test/extensions/filters/http/mcp/e2e/run.sh
```

With `DEMO=1`, the server runs with `--demo`, which adds the simulated service-operations tools of
[`demo_tools.py`](demo_tools.py) to `get_weather`:
- `list_services()`
- `get_service_health(service)`
- `get_incident(service)`
- `recommend_action(service, incident_id)`
- `apply_remediation(service, incident_id)`

Their data is fixed: no external API, no LLM, and nothing real changes. The demo prints these
sections:

| Section | What it shows | Who produces the result |
|---|---|---|
| 1. MCP 2026-07-28 Connection | `Client(url, mode="2026-07-28")`; connecting sends no request: no `initialize`, no `server/discover` | SDK client |
| 2. Tool Discovery | `tools/list`, with its request and response as observed | MCP backend, through Envoy |
| 3. Multi-step Tool Execution | `list_services`, then `get_service_health` of each service, `get_incident` of the degraded one, and `recommend_action`, with their structured results; and a tool error (`isError: true`) for an unknown service | MCP backend, through Envoy |
| 4. Stateless Request Metadata | For each SDK request so far: its `MCP-Protocol-Version`, `Mcp-Method` and `Mcp-Name` headers, its `params._meta`, and no `Mcp-Session-Id`; Envoy forwarded each request, and the server received each one | SDK client sets them; Envoy checks them |
| 5. Header Validation | Raw requests: valid and base64-encoded `Mcp-Name` (forwarded); `Mcp-Method` and `Mcp-Name` mismatches, and a missing `Mcp-Method` or `Mcp-Name` (-32020) | Envoy MCP filter |
| 6. Protocol Version Enforcement | An unsupported version (-32022), a header/`_meta` version mismatch (-32020), and the SDK client through the capped listener (-32022, raised as `MCPError`) | Envoy MCP filter |
| 7. Client Capabilities Validation | A request without `clientCapabilities` (-32602), and the same request with `clientCapabilities: {}` (forwarded) | Envoy MCP filter |
| 8. Optional Advanced Features | `server/discover`; cache hints (`ttlMs`, `cacheScope`) and an SDK cache hit; a multi round-trip request (`resultType: "input_required"`) | SDK client and MCP backend; Envoy only forwards |
| 9. Final Summary | The checks of each section, how many requests Envoy forwarded or answered, the MCP filter's counter changes, and where the logs are | |

For each raw request, the demo prints:
- its method and MCP headers;
- what should happen;
- the HTTP status, and the JSON-RPC error code and message, that came back;
- whether Envoy rejected or forwarded it;
- whether the server received it.

**Everything printed is observed.**
- **SDK requests and responses:** recorded as they leave and reach the client, by httpx2 event
  hooks on the HTTP client that the SDK's transport uses
  (`streamable_http_client(url, http_client=...)`).
- **Forwarded or rejected:** from Envoy's access log (the upstream host and
  `response_code_details`).
- **Received by the server:** from the server's request log.

To find a request in those logs, the demo adds an `X-E2E-Case` header to it. Each step also checks
what it observed. The demo exits 1, and `run.sh` prints `FAIL`, if a check fails. Envoy's access
log and the other files in `RUN_DIR` hold the details.

**Who implements what.** The demo labels each line with the component that produced it:
- **SDK client** (`mcp` 2.2.0):
  - adopts 2026-07-28 with no handshake;
  - puts `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name` and `params._meta` on every request;
  - caches results as the server's hints allow;
  - answers input requests through its elicitation callback, and calls again.
- **Envoy MCP filter**:
  - checks the MCP headers against the body, the protocol version, and that `clientCapabilities`
    is there;
  - rejects invalid requests itself, with JSON-RPC errors, and forwards the rest.
  - It does not cache, answer `server/discover`, or drive multi round-trip requests; it forwards
    each round as an ordinary `tools/call`.
- **MCP backend** (the SDK server):
  - runs the tools and answers `server/discover`;
  - sets the cache hints (`MCPServer(cache_hints=...)`);
  - asks for input with `resultType: "input_required"` and a sealed `requestState`. A tool
    parameter whose `Resolve` resolver returns `Elicit` makes it do so.

Notes:
- The SDK client registers an elicitation callback, for `apply_remediation`'s approval. So its
  `clientCapabilities` is `{"elicitation": {"form": {}, "url": {}}}`, not `{}`.
- The cache hit relies on the `tools/list` hint, `ttlMs` 60000. Section 8 runs seconds after
  section 2.

### Not in the demo

- **`subscriptions/listen` and server-to-client notifications:** they need a long-lived SSE
  response through Envoy, which the demo's request-response steps do not cover.
- **Sampling and roots as input requests:** they use the same multi round-trip mechanism as the
  elicitation, with other client callbacks. One example shows that Envoy forwards the rounds.
- **`Mcp-Param-*` headers and the MCP JSON-REST bridge's `resultType` handling:** they belong to the
  bridge, not to this test of the MCP filter with an MCP backend.

## How the config works

`envoy.yaml` is a template. `render_envoy_config.sh` fills in `__LISTEN_ADDRESS__`, `__PORT__`,
`__CAPPED_PORT__`, `__ADMIN_PORT__`, `__BACKEND_HOST__`, `__BACKEND_PORT__` and `__RUN_DIR__`:

| | `LISTEN_ADDRESS` | `BACKEND_HOST` | `RUN_DIR` |
|---|---|---|---|
| `run.sh` | `127.0.0.1` | `127.0.0.1` | `RUN_DIR` |
| Docker Compose | `0.0.0.0` | `mcp-server` | `/e2e-run` |

- **Listeners:** HTTP on `LISTEN_ADDRESS:PORT` (`mcp_listener`) and `LISTEN_ADDRESS:CAPPED_PORT`
  (`mcp_listener_capped`). They differ only in their `stat_prefix` (`ingress_http` and
  `ingress_http_capped`) and the MCP filter's `max_supported_protocol_version`. That setting is
  per filter, not per route, so the capped case needs a listener of its own. Both write one JSON
  object per request to `RUN_DIR/access.log`, with the listener port, the `X-E2E-Case` header, the
  MCP headers, the MCP filter's dynamic metadata (`%DYNAMIC_METADATA(envoy.filters.http.mcp)%`),
  the response code, details and flags, and the upstream host.
- **MCP filter**, before the router:
  - `traffic_mode: REJECT_NO_MCP`: it answers requests that are not MCP itself, and rejects the
    2026-07-28 requests that break its rules, such as one whose headers do not match its body, or
    whose `params._meta` has no client capabilities. In `PASS_THROUGH` mode, it would forward them.
  - `attribute_source: BODY`: it takes the MCP attributes, which go into the metadata, from the
    JSON-RPC body. For 2026-07-28 requests, it also checks the `Mcp-Method` and `Mcp-Name` headers,
    and the protocol version in `params._meta`, against the body.
  - `request_storage_mode: DYNAMIC_METADATA`: it stores the attributes in the dynamic metadata
    namespace `envoy.filters.http.mcp`, where the access log reads them.
  - `max_supported_protocol_version` (envoyproxy/envoy#47280): `2026-07-28` on the main listener
    and `2025-11-25` on the capped one. The filter answers requests for a newer version, or for one
    it does not know, with -32022. Without this setting, it would accept every protocol version.

  There is no RBAC, no MCP-to-REST transcoding, and no routing on MCP attributes.
- **Routes:** `/mcp` goes to the `mcp_backend` cluster. The route timeout is off (`timeout: 0s`),
  because a Streamable HTTP response may be a long-lived SSE stream.
- **Cluster:** `mcp_backend` is the server, at `BACKEND_HOST:BACKEND_PORT`. It is `STRICT_DNS`
  (IPv4), which takes an IP address or a name. The access log has the address that a name resolves
  to.

`run.sh` and the `envoy` service start Envoy with `--concurrency 1`, `--disable-hot-restart` and
`--file-flush-interval-msec 200`, so that a request's log entry reaches `access.log` soon after the
request ends.

## Inspecting failures

Each run leaves its files in `RUN_DIR`, whose path `run.sh` prints at the end:

| File | |
|---|---|
| `envoy.yaml` | The config Envoy ran with |
| `envoy.log` | Envoy's log |
| `backend.log` | The server's log |
| `backend_requests.jsonl` | The server's request log: one JSON object per request that reached it, with its MCP headers and `X-E2E-Case` |
| `access.log` | Envoy's access log: one JSON object per request, with the MCP filter's metadata |
| `stats.txt` | Envoy's stats, read after the last case |

- **A check failed:** its `FAIL` line says what was expected and what came back. For a raw case, the
  client also prints the case's `access.log` entry. To see where a request went, look up its case
  name in both logs, for example
  `grep '"missing-mcp-name"' "${RUN_DIR}/access.log" "${RUN_DIR}/backend_requests.jsonl"`. A
  request that the server, not Envoy, answered has an upstream host and
  `response_code_details: via_upstream` in `access.log`, and a line in `backend_requests.jsonl`
  with the status that the server answered.
- **Why the filter did something:** run again with `LOG_LEVEL=debug`, and look for the `[mcp]`
  lines in `envoy.log`.
- **Envoy did not start:** `run.sh` prints the `critical` and `error` lines of `envoy.log`. To check
  the config alone, run `"${ENVOY_BIN}" --mode validate -c "${RUN_DIR}/envoy.yaml"`.
- **The server did not start:** `run.sh` prints the end of `backend.log`.
- **The SDK is missing, or is not version 2.2.0:** `run.sh` stops before it builds or starts
  anything, and says which version `PYTHON` has. Install `mcp==2.2.0`, and point `PYTHON` at it.
- **A port is in use:** `run.sh` stops before it starts anything. Stop what listens there, or set
  `PORT`, `CAPPED_PORT`, `ADMIN_PORT` and `BACKEND_PORT` to free ports.
- **With Docker Compose:** the run directory has the same files, except `envoy.log` and
  `backend.log`: they are `docker compose logs envoy` and `docker compose logs mcp-server`. See
  [Logs and results](#run-with-docker-compose). `client_output.txt` has the client's output.
  `LOG_LEVEL=debug` works as for `run.sh`. If Envoy or the server did not start, its log says why.

To send your own requests, start the server and Envoy by hand with a `RUN_DIR`'s config, and send
2026-07-28 requests with their headers and `params._meta`:

```sh
/tmp/mcp-e2e-venv/bin/python3 test/extensions/filters/http/mcp/e2e/mcp_server.py &
"${ENVOY_BIN}" -c "${RUN_DIR}/envoy.yaml" -l debug &
curl -sS http://127.0.0.1:10000/mcp \
  -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
  -H 'mcp-protocol-version: 2026-07-28' -H 'mcp-method: tools/call' -H 'mcp-name: get_weather' \
  -d '{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {
        "name": "get_weather", "arguments": {"city": "Paris"}, "_meta": {
          "io.modelcontextprotocol/protocolVersion": "2026-07-28",
          "io.modelcontextprotocol/clientInfo": {"name": "curl", "version": "1.0.0"},
          "io.modelcontextprotocol/clientCapabilities": {}}}}'
```

## Not covered

Out of this test's scope:
- What the MCP JSON-REST bridge does, such as its parameter mapping, its local handling of
  `server/discover`, and its rejection of the legacy handshake at 2026-07-28
  (envoyproxy/envoy#47619, re-landed as envoyproxy/envoy#47817): that belongs to the E2E test with a
  REST backend. Through the MCP filter, `server/discover` is in the demo, not in the regression
  cases.
- `Mcp-Param-*` headers, which the filter does not check.
- RBAC and transcoding.
- The legacy, stateful protocol (the `initialize` handshake, `Mcp-Session-Id`, the GET stream and
  `DELETE`), up to 2025-11-25.
- Bazel and CI: the test runs by hand, with `run.sh` or Docker Compose.

## Future coverage

Not blocking. Cases that could be added for merged behavior that the suite does not exercise yet:
- A 2026-07-28 notification without client capabilities, which envoyproxy/envoy#47915 exempts from
  its check. `legacy-initialized-notification` has client capabilities, and the SDK sends no
  notifications over HTTP at 2026-07-28.
- A request whose `params._meta` has client capabilities but no protocol version, which passes the
  consistency check of envoyproxy/envoy#47280.
- `attribute_source: HEADERS`, for which envoyproxy/envoy#47915 makes the filter parse the body of
  2026-07-28 requests in `REJECT_NO_MCP` mode; the filter's other modes (`PASS_THROUGH`, `NOOP`);
  and its other options, such as body size limits and duplicate keys. Each needs a filter config,
  and so a listener, of its own.
