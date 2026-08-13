#!/bin/sh

set -eu

TEST_DIR=$(mktemp -d)
trap 'rm -rf "${TEST_DIR}"' EXIT

SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cp "${SOURCE_DIR}/auth.sh" "${SOURCE_DIR}/trace.sh" "${TEST_DIR}/"

key='gatekeeper-redaction-sentinel-key'
id='9001'
expires=$(( $(date +%s) + 300 ))
header=$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | basenc --base64url | tr -d '=')
payload=$(printf '{"id":"%s","exp":%s}' "${id}" "${expires}" | basenc --base64url | tr -d '=')
signature=$(printf '%s' "${header}.${payload}" | openssl dgst -hmac "${key}" -sha256 -r -binary | basenc --base64url | tr -d '=')
token="${header}.${payload}.${signature}"
log_path="${TEST_DIR}/gatekeeper.log"

printf 'ukey_%s=%s\nugroups_%s=stats\n' "${id}" "${key}" "${id}" > "${TEST_DIR}/keys.properties"
printf 'action_helloworld=stats\n' > "${TEST_DIR}/api.properties"

(
  cd "${TEST_DIR}"
  TRACING=1 \
  GATEKEEPER_LOG_PATH="${log_path}" \
  HTTP_AUTHORIZATION="Bearer ${token}" \
  REQUEST_URI=/v0/helloworld \
  sh -c '. ./auth.sh' >/dev/null
)

grep -F 'Valid signature' "${log_path}" >/dev/null
for secret in "${key}" "${token}" "${header}" "${payload}" "${signature}"; do
  if grep -F "${secret}" "${log_path}" >/dev/null; then
    echo "credential material was written to the Gatekeeper trace" >&2
    exit 1
  fi
done

: > "${log_path}"
(
  cd "${TEST_DIR}"
  TRACING=0 \
  GATEKEEPER_LOG_PATH="${log_path}" \
  HTTP_AUTHORIZATION="Bearer ${token}" \
  REQUEST_URI=/v0/helloworld \
  sh -c '. ./auth.sh' >/dev/null
)

[ ! -s "${log_path}" ]

grep -F 'proxy_set_header Authorization "";' "${SOURCE_DIR}/default.conf" >/dev/null
echo "ok - Gatekeeper tracing does not disclose credentials"
