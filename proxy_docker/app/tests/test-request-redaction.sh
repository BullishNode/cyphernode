#!/bin/sh

set -eu

TEST_FILE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -d "${TEST_FILE_DIR}/../script" ]; then
  SCRIPT_DIR=$(CDPATH= cd -- "${TEST_FILE_DIR}/../script" && pwd)
elif [ -f "${TEST_FILE_DIR}/../requesthandler.sh" ]; then
  SCRIPT_DIR=$(CDPATH= cd -- "${TEST_FILE_DIR}/.." && pwd)
else
  echo "could not locate proxy scripts" >&2
  exit 1
fi

TEST_DIR=$(mktemp -d)
trap 'rm -rf "${TEST_DIR}"' EXIT
cp "${SCRIPT_DIR}"/*.sh "${TEST_DIR}/"
mkdir "${TEST_DIR}/db"
: > "${TEST_DIR}/db/config.sh"

authorization_sentinel='proxy-authorization-sentinel'
body_sentinel='proxy-body-sentinel'
body=$(printf '{"value":"%s"}' "${body_sentinel}")
content_length=$(printf '%s' "${body}" | wc -c | tr -d ' ')
log_path="${TEST_DIR}/proxy.log"

run_request() {
  tracing=$1
  (
    cd "${TEST_DIR}"
    printf 'POST /helloworld HTTP/1.1\r\nAuthorization: Bearer %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' \
      "${authorization_sentinel}" "${content_length}" "${body}" |
      TRACING="${tracing}" PROXY_LOG_PATH="${log_path}" sh ./requesthandler.sh >/dev/null
  )
}

run_request 1
grep -F 'Entering main()' "${log_path}" >/dev/null
for secret in "${authorization_sentinel}" "${body_sentinel}"; do
  if grep -F "${secret}" "${log_path}" >/dev/null; then
    echo "request material was written to the proxy trace" >&2
    exit 1
  fi
done

: > "${log_path}"
run_request 0
[ ! -s "${log_path}" ]

echo "ok - proxy tracing does not disclose request credentials or bodies"
