#!/bin/sh
#
# Unit test for Ark send, board, offboard and watch request handling with
# stubbed barkd, PostgreSQL and broker. Runs anywhere with sh and jq.
#
#   cd proxy_docker/app/script && sh ../tests/test-ark-send.sh

set -u

SQL_LOG=$(mktemp)
BARKD_LOG=$(mktemp)
MQTT_LOG=$(mktemp)
trap 'rm -f "${SQL_LOG}" "${BARKD_LOG}" "${MQTT_LOG}"' EXIT

TRACING=
BARKD_URL=stub
BARKD_CURL_CFG=/dev/null
BARKD_TOKEN_FILE=/dev/null

. ./ark_watchrequest.sh

fail=0
jqcheck() {
  [ "$(printf '%s' "${1}" | jq -r "${2}" 2>/dev/null)" = "true" ]
}
check() {
  if eval "${2}"; then
    echo "ok   - ${1}"
  else
    echo "FAIL - ${1}"
    fail=1
  fi
}

# --- stubs -------------------------------------------------------------------

DEST=ark1qpzry9x8gf2tvdw0s3jn54khce6mua7lqpzry9x8gf2tvdw0s3jn54khce6mua7l

# Movements 4 and 5 already paid 500 sats to DEST. Movement 6 appears once
# /wallet/send has been called; NEW_MOVEMENTS adds more look-alikes.
BARKD_MODE=ok
CONNECTED=true
NEW_MOVEMENTS=
SQL_MODE=ok
barkd_call() {
  rm -f "$(barkd_http_code_file)"
  printf '%s %s\n' "${1}" "${2}" >> "${BARKD_LOG}"
  [ "${1}" != POST ] || printf 'barkd POST %s\n' "${2}" >> "${SQL_LOG}"
  if [ "${LOCK_READ_ONCE:-}" = true ] && [ "${2}" = /wallet/connected ] && [ ! -e "${BARKD_LOG}.read-lock" ]; then
    touch "${BARKD_LOG}.read-lock"
    printf 409 > "$(barkd_http_code_file)"
    echo '{"message":"database is locked"}'
    return 2
  fi
  if [ -n "${LOCK_SEND_ONCE:-}" ] && [ "${2}" = /wallet/send ] && [ ! -e "${BARKD_LOG}.send-lock" ]; then
    touch "${BARKD_LOG}.send-lock"
    printf 409 > "$(barkd_http_code_file)"
    echo '{"message":"database is locked"}'
    return 2
  fi
  case "${BARKD_MODE}" in
    ok)
      case "${2}" in
        /wallet/send) echo '{"message":"Payment sent successfully"}'; return 0 ;;
        /wallet/connected) echo "{\"connected\":${CONNECTED}}"; return 0 ;;
        /history*)
          movements='{"id":4,"status":"successful","sent_to":[{"destination":{"type":"ark","value":"'${DEST}'"},"amount_sat":500}]},{"id":5,"status":"successful","sent_to":[{"destination":{"type":"ark","value":"'${DEST}'"},"amount_sat":500}]}'
          if grep -q '^POST /wallet/send$' "${BARKD_LOG}" &&
             { [ "${LOCK_SEND_ONCE:-}" != uncommitted ] || [ "$(grep -c '^POST /wallet/send$' "${BARKD_LOG}")" -ge 2 ]; }; then
            movements="${movements}"',{"id":6,"status":"successful","sent_to":[{"destination":{"type":"ark","value":"'${DEST}'"},"amount_sat":500}]}'"${NEW_MOVEMENTS}"
          fi
          echo "[${movements}]"; return 0 ;;
        /boards/board-amount) echo '{"funding_tx":{"txid":"txid-b"},"vtxos":["v1"],"movement_id":14}'; return 0 ;;
        /wallet/offboard/vtxos) echo '{"offboard_txid":"txid-o","movement_id":15}'; return 0 ;;
      esac ;;
    down) rm -f "$(barkd_http_code_file)"; return 1 ;;
    down_after)
      case "${2}" in
        /history*) echo '[]'; return 0 ;;
        /wallet/connected) echo '{"connected":true}'; return 0 ;;
        *) rm -f "$(barkd_http_code_file)"; return 1 ;;
      esac ;;
    no_history)
      case "${2}" in
        /history*) rm -f "$(barkd_http_code_file)"; return 1 ;;
        /wallet/send) echo '{"message":"Payment sent successfully"}'; return 0 ;;
        /wallet/connected) echo '{"connected":true}'; return 0 ;;
        *) rm -f "$(barkd_http_code_file)"; return 1 ;;
      esac ;;
    refused)
      case "${2}" in
        /wallet/connected) echo '{"connected":true}'; return 0 ;;
        /history*) echo '[]'; return 0 ;;
        /wallet/send) printf 409 > "$(barkd_http_code_file)"; echo '{"message":"Insufficient money available. Needed 0.00001000 BTC but 0.00000500 BTC is available"}'; return 2 ;;
        *) printf 422 > "$(barkd_http_code_file)"; echo '{"message":"insufficient funds"}'; return 2 ;;
      esac ;;
    server_error) printf 503 > "$(barkd_http_code_file)"; echo '{"message":"service unavailable"}'; return 2 ;;
  esac
}

sql() {
  printf '%s\n' "${1}" >> "${SQL_LOG}"
  case "${1}" in
    "INSERT INTO ark_job (kind, label, callback_url, vtxos, status) VALUES ('board', 'dupjob'"*) ;;
    "INSERT INTO ark_job (kind, label, callback_url, vtxos, status) VALUES ('offboard', 'dupjob'"*) ;;
    "INSERT INTO ark_job"*)
      [ "${SQL_MODE}" != fail_insert ] || return 1
      printf '9' ;;
    "UPDATE ark_job"*) [ "${SQL_MODE}" != fail_update ] ;;
    "SELECT row_to_json(t) FROM (SELECT id, kind, label, status, txid, movement_id, vtxos, callback_url, calledback, error FROM ark_job WHERE label='dupjob') t")
      printf '%s\n' '{"id":29,"kind":"board","label":"dupjob","status":"successful","txid":"txid-existing","movement_id":23,"vtxos":"[\"existing-vtxo\"]","callback_url":null,"calledback":true,"error":null}' ;;
    *) ;;
  esac
}

psql() {
  local statement
  statement=$(cat)
  printf '%s\n' "${statement}" "$@" >> "${SQL_LOG}"
  [ "${SQL_MODE}" != fail_watch ] || return 1
  case "${statement}" in
    "INSERT INTO ark_watching"*) printf '7' ;;
  esac
}

mosquitto_pub() {
  printf '%s %s\n' "${4}" "${6}" >> "${MQTT_LOG}"
}

# --- ark_send ----------------------------------------------------------------

out=$(ark_send '{"destination":"bc1qnotark","amount":500}')
check "non-Ark destination is refused" "jqcheck '${out}' '.error.code == -5'"

out=$(ark_send '{"destination":"'${DEST}'","amount":"12.5"}')
check "non-integer amount is refused" "jqcheck '${out}' '.error.code == -32602'"

out=$(ark_send '{"destination":"'${DEST}'","amount":0}')
check "zero amount is refused before barkd is called" \
  "jqcheck '${out}' '.error.code == -32602' && ! grep -q 'POST /wallet/send' '${BARKD_LOG}'"

CONNECTED=false
out=$(ark_send '{"destination":"'${DEST}'","amount":500}')
check "server not connected is refused before anything is sent" \
  "jqcheck '${out}' '.error.code == -32003' && ! grep -q 'POST /wallet/send' '${BARKD_LOG}'"
CONNECTED=true

out=$(ark_send '{"destination":"'${DEST}'","amount":500}')
check "successful send is accepted with the movement made after it, not an older one" \
  "jqcheck '${out}' '.status == \"accepted\" and .movementId == 6 and .details.destination == \"${DEST}\" and .details.amount_sat == 500'"
check "send without eventMessage publishes nothing" "! grep -q '^ark_send' '${MQTT_LOG}'"

: > "${BARKD_LOG}"
out=$(ark_send '{"destination":"'${DEST}'","amount":500,"eventMessage":"ZXZlbnQ="}')
check "eventMessage is published with the movement id" \
  "grep -q '^ark_send {\"destination\":\"${DEST}\",\"amount_sat\":500,\"movementId\":6,\"eventMessage\":\"ZXZlbnQ=\"}$' '${MQTT_LOG}'"

: > "${BARKD_LOG}"
NEW_MOVEMENTS=',{"id":7,"status":"successful","sent_to":[{"destination":{"type":"ark","value":"'${DEST}'"},"amount_sat":500}]}'
out=$(ark_send '{"destination":"'${DEST}'","amount":500}')
check "two look-alike movements after the send leave movementId null" \
  "jqcheck '${out}' '.status == \"accepted\" and .movementId == null'"
NEW_MOVEMENTS=

: > "${BARKD_LOG}"
BARKD_MODE=no_history
out=$(ark_send '{"destination":"'${DEST}'","amount":500}')
check "history unavailable prevents a send that cannot be reconciled" \
  "jqcheck '${out}' '.error.code == -32001' && ! grep -q 'POST /wallet/send' '${BARKD_LOG}'"

: > "${BARKD_LOG}"
BARKD_MODE=down
out=$(ark_send '{"destination":"'${DEST}'","amount":500}')
check "barkd unreachable before the send is refused" \
  "jqcheck '${out}' '.error.code == 1' && ! grep -q 'POST /wallet/send' '${BARKD_LOG}'"

BARKD_MODE=down_after
out=$(ark_send '{"destination":"'${DEST}'","amount":500}')
check "transport failure after the send reports the outcome unknown" "jqcheck '${out}' '.error.code == -32001'"

BARKD_MODE=refused
out=$(ark_send '{"destination":"'${DEST}'","amount":500}')
check "barkd refusal is reported with its status and message" \
  "jqcheck '${out}' '.error.code == 409 and (.error.message | startswith(\"Insufficient money available\"))'"
check "insufficient funds is published like spend does" \
  "grep -q '^insufficientfunds {\"method\":\"ark_send\",\"error\":\"Insufficient money available' '${MQTT_LOG}'"

BARKD_MODE=ok
: > "${BARKD_LOG}"
LOCK_READ_ONCE=true
out=$(ark_send '{"destination":"'${DEST}'","amount":500}')
check "a database lock on a read is retried" \
  "jqcheck '${out}' '.status == \"accepted\"' && [ \"\$(grep -c '^GET /wallet/connected' '${BARKD_LOG}')\" -eq 2 ]"
LOCK_READ_ONCE=

: > "${BARKD_LOG}"
LOCK_SEND_ONCE=uncommitted
out=$(ark_send '{"destination":"'${DEST}'","amount":500}')
check "a locked send without a movement stays uncertain and is not resubmitted" \
  "jqcheck '${out}' '.error.code == -32001 and (.error.message | contains(\"outcome unknown\"))' && [ \"\$(grep -c '^POST /wallet/send' '${BARKD_LOG}')\" -eq 1 ]"
rm "${BARKD_LOG}.send-lock"

: > "${BARKD_LOG}"
LOCK_SEND_ONCE=recorded
out=$(ark_send '{"destination":"'${DEST}'","amount":500}')
check "a movement after a locked send prevents a second payment" \
  "jqcheck '${out}' '.error.code == -32001' && [ \"\$(grep -c '^POST /wallet/send' '${BARKD_LOG}')\" -eq 1 ]"
LOCK_SEND_ONCE=
rm "${BARKD_LOG}.send-lock" "${BARKD_LOG}.read-lock"

# --- ark_board ---------------------------------------------------------------

BARKD_MODE=ok
: > "${BARKD_LOG}"
: > "${SQL_LOG}"
out=$(ark_board '{"amount":1000,"label":"topup-1","callbackURL":"http://app/job?x=1|2"}')
check "board records the job before barkd is called" \
  "jqcheck '${out}' '.id == 9 and .txid == \"txid-b\" and .vtxos == [\"v1\"] and .movementId == 14' &&
   sed -n '1p' '${SQL_LOG}' | grep -q '^INSERT INTO ark_job' &&
   grep -Fxq 'barkd POST /boards/board-amount' '${SQL_LOG}'"
check "board binds the funding txid, VTXOs and movement ID" \
  "grep -Fq \"UPDATE ark_job SET txid='txid-b', vtxos='[\\\"v1\\\"]', movement_id=COALESCE(14, movement_id) WHERE id=9\" '${SQL_LOG}'"

: > "${BARKD_LOG}"
out=$(ark_board '{"amount":1000,"label":"dupjob"}')
check "retry of the same board label returns the completed original job" \
  "jqcheck '${out}' '.id == 29 and .label == \"dupjob\" and .status == \"successful\" and .movementId == 23 and .vtxos == [\"existing-vtxo\"]' &&
   [ ! -s '${BARKD_LOG}' ]"

out=$(ark_offboard '{"vtxos":["original-vtxo"],"label":"dupjob"}')
check "an offboard cannot reuse a board label" \
  "jqcheck '${out}' '.error.code == -32000' && [ ! -s '${BARKD_LOG}' ]"

: > "${SQL_LOG}"
BARKD_MODE=refused
out=$(ark_board '{"amount":1000,"label":"topup-2"}')
check "definitive board refusal records the failure" \
  "jqcheck '${out}' '.error.code == 422' && grep -Fq \"UPDATE ark_job SET status='failed', error='insufficient funds' WHERE id=9 AND status='pending'\" '${SQL_LOG}'"

: > "${SQL_LOG}"
: > "${BARKD_LOG}"
BARKD_MODE=down
out=$(ark_board '{"amount":1000,"label":"topup-timeout"}')
check "board transport timeout keeps the original label pending" \
  "jqcheck '${out}' '.id == 9 and .label == \"topup-timeout\" and .status == \"pending\" and .error.code == -32001' &&
   [ \"\$(grep -c '^POST /boards/board-amount$' '${BARKD_LOG}')\" -eq 1 ] &&
   ! grep -q 'UPDATE ark_job' '${SQL_LOG}'"

: > "${SQL_LOG}"
: > "${BARKD_LOG}"
BARKD_MODE=server_error
out=$(ark_offboard '{"vtxos":["original-vtxo"],"label":"exit-server-error"}')
check "offboard HTTP 503 keeps the original label pending" \
  "jqcheck '${out}' '.id == 9 and .label == \"exit-server-error\" and .status == \"pending\" and .error.code == -32001' &&
   [ \"\$(grep -c '^POST /wallet/offboard/vtxos$' '${BARKD_LOG}')\" -eq 1 ] &&
   ! grep -q 'UPDATE ark_job' '${SQL_LOG}'"

BARKD_MODE=ok
: > "${BARKD_LOG}"
SQL_MODE=fail_insert
out=$(ark_board '{"amount":1000,"label":"topup-no-insert"}')
check "failed job insertion prevents submission" \
  "jqcheck '${out}' '.error.code == -32002' && [ ! -s '${BARKD_LOG}' ]"

SQL_MODE=fail_update
out=$(ark_offboard '{"vtxos":["original-vtxo"],"label":"exit-no-binding"}')
check "failed receipt binding reports the active offboard pending" \
  "jqcheck '${out}' '.id == 9 and .label == \"exit-no-binding\" and .status == \"pending\" and .error.code == -32001' &&
   [ \"\$(grep -c '^POST /wallet/offboard/vtxos$' '${BARKD_LOG}')\" -eq 1 ]"
SQL_MODE=ok

# --- ark_watch ---------------------------------------------------------------

: > "${SQL_LOG}"
out=$(ark_watchrequest '{"address":"t'${DEST}'","callbackURL":"http://app/cb","label":"o-1","eventMessage":"ZQ==","expectedAmount":100}')
check "watch is inserted and echoed" \
  "jqcheck '${out}' '.id == 7 and .inserted == true and .expectedAmount == 100 and .eventMessage == \"ZQ==\"'"
check "watch binds the address and callback for the upsert" \
  "grep -Fq \"VALUES (:'address', true, NULLIF(:'callback', '')\" '${SQL_LOG}' &&
   grep -Fq \"ON CONFLICT (address, COALESCE(callback_url, '')) DO UPDATE SET\" '${SQL_LOG}' &&
   grep -Fxq 'address=t${DEST}' '${SQL_LOG}' && grep -Fxq 'callback=http://app/cb' '${SQL_LOG}'"

: > "${SQL_LOG}"
out=$(ark_watchrequest '{"address":"1BitcoinAddress","callbackURL":"http://app/cb"}')
check "watch refuses a non-Ark address before SQL" \
  "jqcheck '${out}' '.error.code == -5' && [ ! -s '${SQL_LOG}' ]"

newline_request=$(jq -cn --arg address "t${DEST}" '{address: ($address + "\n")}')
out=$(ark_watchrequest "${newline_request}")
check "watch refuses a trailing newline before SQL" \
  "jqcheck '${out}' '.error.code == -5' && [ ! -s '${SQL_LOG}' ]"

with_extra_line="t${DEST}
extra-line"
out=$(ark_unwatchrequest "" "${with_extra_line}" "")
check "unwatch refuses a multiline address before SQL" \
  "jqcheck '${out}' '.error.code == -5' && [ ! -s '${SQL_LOG}' ]"

out=$(ark_unwatchrequest "" "t${DEST}" "http://app/cb")
check "unwatch by address binds the address and callback" \
  "jqcheck '${out}' '.address == \"t${DEST}\" and .callbackURL == \"http://app/cb\"' &&
   grep -Fq \"WHERE address=:'address'\" '${SQL_LOG}' &&
   grep -Fq \"callback_url=:'callback'\" '${SQL_LOG}' &&
   grep -Fxq 'address=t${DEST}' '${SQL_LOG}' && grep -Fxq 'callback=http://app/cb' '${SQL_LOG}'"

out=$(ark_unwatchrequest "12" "" "")
check "unwatch by id binds the numeric id" \
  "jqcheck '${out}' '.id == 12' && grep -Fq \"WHERE id=:'id'::integer\" '${SQL_LOG}' && grep -Fxq 'id=12' '${SQL_LOG}'"

: > "${SQL_LOG}"
out=$(ark_unwatchrequest "not-an-id" "" "")
check "unwatch refuses a non-integer id before SQL" \
  "jqcheck '${out}' '.error.code == -32602' && [ ! -s '${SQL_LOG}' ]"

SQL_MODE=fail_watch
watch_rc=0
out=$(ark_watchrequest '{"address":"t'${DEST}'"}') || watch_rc=$?
check "failed watch insert cannot report success" \
  "[ '${watch_rc}' -ne 0 ] && jqcheck '${out}' '.id == null and .inserted == false'"

exit ${fail}
