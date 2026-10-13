#!/bin/sh
#
# Renders envoy.yaml, the Envoy config template of the MCP filter end-to-end test: fills in its
# __PLACEHOLDERS__. run.sh and the Docker Compose envoy service both use it, so that they run the
# same config. POSIX sh, for the official Envoy image's /bin/sh. See README.md.
#
# Usage: render_envoy_config.sh --template FILE --output FILE --run-dir DIR \
#          --listen-address ADDRESS --port PORT --capped-port PORT --admin-port PORT \
#          --backend-host HOST --backend-port PORT

set -eu

usage() {
  echo "usage: $0 --template FILE --output FILE --run-dir DIR --listen-address ADDRESS" \
    "--port PORT --capped-port PORT --admin-port PORT --backend-host HOST --backend-port PORT" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage
  case "$1" in
    --template) template="$2" ;;
    --output) output="$2" ;;
    --run-dir) run_dir="$2" ;;
    --listen-address) listen_address="$2" ;;
    --port) port="$2" ;;
    --capped-port) capped_port="$2" ;;
    --admin-port) admin_port="$2" ;;
    --backend-host) backend_host="$2" ;;
    --backend-port) backend_port="$2" ;;
    *) usage ;;
  esac
  shift 2
done
for value in "${template:-}" "${output:-}" "${run_dir:-}" "${listen_address:-}" "${port:-}" \
  "${capped_port:-}" "${admin_port:-}" "${backend_host:-}" "${backend_port:-}"; do
  [ -n "${value}" ] || usage
done

# __PORT__ goes last, after the placeholders whose names end in _PORT__.
sed -e "s|__RUN_DIR__|${run_dir}|g" \
  -e "s|__LISTEN_ADDRESS__|${listen_address}|g" \
  -e "s|__CAPPED_PORT__|${capped_port}|g" \
  -e "s|__ADMIN_PORT__|${admin_port}|g" \
  -e "s|__BACKEND_HOST__|${backend_host}|g" \
  -e "s|__BACKEND_PORT__|${backend_port}|g" \
  -e "s|__PORT__|${port}|g" \
  "${template}" > "${output}"
# A placeholder that this script does not know would be left in the config, outside comments.
if sed -e 's/#.*//' "${output}" | grep -q "__[A-Z_]*__"; then
  echo "ERROR: ${output} still has placeholders:" >&2
  sed -e 's/#.*//' "${output}" | grep -n "__[A-Z_]*__" >&2
  exit 1
fi
