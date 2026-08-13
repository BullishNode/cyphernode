#!/bin/sh

set -eu

TRACING=
TEST_FILE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -d "${TEST_FILE_DIR}/../script" ]; then
  SCRIPT_DIR=$(CDPATH= cd -- "${TEST_FILE_DIR}/../script" && pwd)
elif [ -f "${TEST_FILE_DIR}/../sendtobitcoinnode.sh" ]; then
  SCRIPT_DIR=$(CDPATH= cd -- "${TEST_FILE_DIR}/.." && pwd)
else
  echo "could not locate proxy scripts" >&2
  exit 1
fi
TEST_DIR=$(mktemp -d)
trap 'rm -rf "${TEST_DIR}"' EXIT

fail() {
  echo "not ok - $1" >&2
  exit 1
}

pass() {
  echo "ok - $1"
}

cd "${SCRIPT_DIR}"
. ./sendtobitcoinnode.sh
. ./sendtoelementsnode.sh
trace() { :; }
trace_rc() { :; }

CURL_ARGS_FILE=${TEST_DIR}/curl-args
CURL_RESPONSE='{"result":{"value":1},"error":null}'
CURL_RETURN_CODE=0

curl() {
  : > "${CURL_ARGS_FILE}"
  for arg in "$@"; do
    printf '%s\n' "${arg}" >> "${CURL_ARGS_FILE}"
  done
  printf '%s\n' "${CURL_RESPONSE}"
  return "${CURL_RETURN_CODE}"
}

assert_rpc_failures() {
  sender=$1
  url=$2

  CURL_RESPONSE='not-json'
  if "${sender}" "${url}" /tmp/rpc.conf '{"method":"getbalances"}' >/dev/null; then
    fail "${sender} accepted malformed JSON"
  fi

  CURL_RESPONSE='{"result":{},"error":{"code":-1,"message":"failure"}}'
  if "${sender}" "${url}" /tmp/rpc.conf '{"method":"getbalances"}' >/dev/null; then
    fail "${sender} accepted a JSON-RPC error"
  fi

  CURL_RESPONSE='{"result":{}}'
  if "${sender}" "${url}" /tmp/rpc.conf '{"method":"getbalances"}' >/dev/null; then
    fail "${sender} accepted a response without an error field"
  fi

  CURL_RESPONSE='{"result":{},"error":null}'
  CURL_RETURN_CODE=22
  if "${sender}" "${url}" /tmp/rpc.conf '{"method":"getbalances"}' >/dev/null; then
    fail "${sender} hid an HTTP failure"
  fi
  CURL_RETURN_CODE=0
}

assert_rpc_failures send_to_bitcoin_node http://bitcoin:18443/wallet/test.dat
assert_rpc_failures send_to_elements_node http://elements:18884/wallet/test.dat
pass "Bitcoin and Elements RPC wrappers reject malformed, error, and HTTP-failure responses"

SPENDER_BTC_NODE_RPC_URL=http://bitcoin:18443/wallet
SPENDER_BTC_NODE_RPC_CFG=/tmp/bitcoin.conf
SPENDER_ELEMENTS_NODE_RPC_URL=http://elements:18884/wallet
SPENDER_ELEMENTS_NODE_RPC_CFG=/tmp/elements.conf
CURL_RESPONSE='{"result":{"mine":{}},"error":null}'

send_getbalances_to_spender_wallet_name 'nested/reserve wallet.dat' >/dev/null || fail "Bitcoin exact wallet was rejected"
grep -Fx -- '--fail' "${CURL_ARGS_FILE}" >/dev/null || fail "Bitcoin curl does not fail on HTTP errors"
grep -Fx -- '--path-as-is' "${CURL_ARGS_FILE}" >/dev/null || fail "Bitcoin curl can normalize literal wallet paths"
grep -Fx 'http://bitcoin:18443/wallet/nested%2Freserve%20wallet.dat' "${CURL_ARGS_FILE}" >/dev/null || fail "Bitcoin exact wallet name was not encoded"

send_getbalances_to_spender_wallet_name '.' >/dev/null || fail "Bitcoin dot wallet was rejected"
grep -Fx 'http://bitcoin:18443/wallet/.' "${CURL_ARGS_FILE}" >/dev/null || fail "Bitcoin literal dot wallet path changed"

send_getbalances_to_elements_spender_wallet_name '..' >/dev/null || fail "Elements dot wallet was rejected"
grep -Fx -- '--fail' "${CURL_ARGS_FILE}" >/dev/null || fail "Elements curl does not fail on HTTP errors"
grep -Fx -- '--path-as-is' "${CURL_ARGS_FILE}" >/dev/null || fail "Elements curl can normalize literal wallet paths"
grep -Fx 'http://elements:18884/wallet/..' "${CURL_ARGS_FILE}" >/dev/null || fail "Elements literal dot wallet path changed"
pass "literal wallet names are encoded and sent without curl path normalization"

. ./walletoperations.sh
. ./elements_walletoperations.sh
trace() { :; }
trace_rc() { :; }

CURL_RESPONSE='{"result":null,"error":null}'
if getbalances "" 'bitcoin-wallet.dat' >/dev/null; then
  fail "Bitcoin getbalances accepted a non-object result"
fi
if elements_getbalances "" 'elements-wallet.dat' >/dev/null; then
  fail "Elements getbalances accepted a non-object result"
fi

CURL_RESPONSE='{"result":{"mine":{"trusted":0}},"error":null}'
bitcoin_response=$(getbalances "" 'bitcoin-wallet.dat') || fail "Bitcoin getbalances rejected a valid result"
elements_response=$(elements_getbalances "" 'elements-wallet.dat') || fail "Elements getbalances rejected a valid result"
printf '%s' "${bitcoin_response}" | jq -e '.balances.mine.trusted == 0' >/dev/null || fail "Bitcoin balance response changed shape"
printf '%s' "${elements_response}" | jq -e '.balances.mine.trusted == 0' >/dev/null || fail "Elements balance response changed shape"
pass "balance handlers preserve valid results and propagate invalid result failures"
