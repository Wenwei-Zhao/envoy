#!/bin/sh
#
# The envoy service's entrypoint, in compose.yaml, run by the official Envoy image's /bin/sh.
# Renders envoy.yaml, the template that run.sh uses too, for the containers: Envoy listens on all
# of its container's interfaces, so that the mcp-client service can reach it as envoy, and
# forwards to the mcp-server service. Then starts Envoy through the image's own entrypoint, with
# run.sh's flags. See README.md.

set -eu

e2e_dir="$(cd "$(dirname "$0")/.." && pwd)"
sh "${e2e_dir}/render_envoy_config.sh" --template "${e2e_dir}/envoy.yaml" \
  --output "${E2E_RUN_DIR}/envoy.yaml" --run-dir "${E2E_RUN_DIR}" --listen-address 0.0.0.0 \
  --port "${ENVOY_PORT}" --capped-port "${ENVOY_CAPPED_PORT}" --admin-port "${ENVOY_ADMIN_PORT}" \
  --backend-host "${MCP_SERVER_HOST}" --backend-port "${MCP_SERVER_PORT}"

# One worker, and access log entries written out every 200 ms, as with run.sh.
exec /docker-entrypoint.sh envoy -c "${E2E_RUN_DIR}/envoy.yaml" -l "${LOG_LEVEL:-info}" \
  --concurrency 1 --disable-hot-restart --file-flush-interval-msec 200
