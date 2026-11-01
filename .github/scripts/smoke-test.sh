#!/usr/bin/env bash
# =============================================================================
# Smoke test for the add-on image without the Home Assistant Supervisor.
#
# Usage: smoke-test.sh <image> [expected-silverbullet-version]
#
# Checks: /.instance answers (and reports the expected version), the space is
# protected (401 without login), login works, a page can be written, read and
# deleted, and the container stops cleanly with exit code 0.
# Needs: docker, curl. Port 3000 on the host must be free (override: SMOKE_PORT).
# =============================================================================
set -euo pipefail

IMAGE="${1:?usage: smoke-test.sh <image> [expected-silverbullet-version]}"
EXPECTED="${2:-}"
PORT="${SMOKE_PORT:-3000}"
NAME="sb-smoke-$$"
WORK="$(mktemp -d)"
BASE="http://127.0.0.1:${PORT}"
USER_NAME="admin"
USER_PASS="smoke-test-pass"

cleanup() {
    docker rm -f "${NAME}" > /dev/null 2>&1 || true
    # The container creates files as root, so empty the directories from inside an image first.
    docker run --rm --entrypoint rm -v "${WORK}:/work" "${IMAGE}" -rf /work/data /work/share > /dev/null 2>&1 || true
    rm -rf "${WORK}" || true
}
trap cleanup EXIT

fail() {
    echo "::error::$*"
    echo "--- container log (last 40 lines) ---"
    docker logs "${NAME}" 2>&1 | tail -n 40 || true
    exit 1
}

http_code() {
    curl -s -o /dev/null -w '%{http_code}' "$@"
}

mkdir -p "${WORK}/data" "${WORK}/share"
cat > "${WORK}/data/options.json" <<EOF
{"sb_user":"${USER_NAME}:${USER_PASS}","space_path":"/share/silverbullet/space","enable_mcp":false,"mcp_token":"","additional_args":""}
EOF

docker run -d --name "${NAME}" -p "127.0.0.1:${PORT}:3000" \
    -v "${WORK}/data:/data" -v "${WORK}/share:/share" "${IMAGE}" > /dev/null

# 1. Start: /.instance must answer 200
READY=false
for _ in $(seq 1 120); do
    if [[ "$(http_code "${BASE}/.instance")" == "200" ]]; then
        READY=true
        break
    fi
    sleep 1
done
[[ "${READY}" == "true" ]] || fail "/.instance did not answer 200 within 120 s"
INSTANCE=$(curl -s "${BASE}/.instance")
echo "ok: /.instance -> ${INSTANCE}"

if [[ -n "${EXPECTED}" ]]; then
    grep -qF "\"version\":\"${EXPECTED}" <<< "${INSTANCE}" \
        || fail "expected SilverBullet ${EXPECTED}, got: ${INSTANCE}"
    echo "ok: SilverBullet version ${EXPECTED}"
fi

# 2. Authentication
[[ "$(http_code "${BASE}/.fs/index.md")" == "401" ]] || fail "space is reachable without login"
echo "ok: 401 without login"

JAR="${WORK}/cookies"
[[ "$(http_code -c "${JAR}" -X POST --data-urlencode "username=${USER_NAME}" \
    --data-urlencode "password=${USER_PASS}" "${BASE}/.auth")" == "200" ]] || fail "login failed"
echo "ok: login"

# 3. Write, read, delete
PAGE="${BASE}/.fs/Smoke-Test/probe.md"
[[ "$(http_code -b "${JAR}" -X PUT -H 'Content-Type: text/markdown' --data 'smoke-test' "${PAGE}")" == "200" ]] \
    || fail "PUT failed"
[[ "$(curl -s -b "${JAR}" "${PAGE}")" == "smoke-test" ]] || fail "GET returned unexpected content"
[[ "$(http_code -b "${JAR}" -X DELETE "${PAGE}")" == "200" ]] || fail "DELETE failed"
[[ "$(http_code -b "${JAR}" "${PAGE}")" == "404" ]] || fail "page still exists after DELETE"
echo "ok: PUT/GET/DELETE"

# 4. Clean stop
docker stop -t 20 "${NAME}" > /dev/null
EXIT_CODE=$(docker inspect "${NAME}" --format '{{.State.ExitCode}}')
[[ "${EXIT_CODE}" == "0" ]] || fail "container exited with code ${EXIT_CODE}"
docker logs "${NAME}" 2>&1 | grep -q "shut down cleanly" || fail "no 'shut down cleanly' in the log"
echo "ok: clean stop (exit 0)"

echo "Smoke test passed for ${IMAGE}"
