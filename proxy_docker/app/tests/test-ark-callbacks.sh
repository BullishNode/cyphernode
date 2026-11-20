#!/bin/sh
#
# Unit test for the Ark callback and catch-up logic. Runs anywhere with sh,
# jq and flock: barkd, PostgreSQL and the notifier are replaced by stubs that
# record what they were asked to do.
#
#   cd proxy_docker/app/script && sh ../tests/test-ark-callbacks.sh

set -u

SQL_LOG=$(mktemp)
NOTIFY_LOG=$(mktemp)
ARK_LOCK_DIR=$(mktemp -d)

TRACING=
BARKD_URL=stub
BARKD_CURL_CFG=/dev/null
BARKD_TOKEN_FILE=/dev/null
TOR_ADDR_WATCH_WEBHOOKS=
TOR_TXID_WATCH_WEBHOOKS=

. ./ark_manage_missed.sh
trap 'rm -f "${SQL_LOG}" "${NOTIFY_LOG}"; rm -rf "${ARK_LOCK_DIR}"' EXIT

# --- stubs -------------------------------------------------------------------

# Watch 7 on ark1receiver with a callback; board job 3 waits for vtxo "v-board".
# Labels and callback URLs contain the psql field separator on purpose.
sql() {
  printf '%s\n' "${1}" >> "${SQL_LOG}"
  case "${1}" in
    "UPDATE ark_job SET "*"movement_id=5"*) [ -z "${FAIL_WRITE:-}" ] || return 1 ;;
    "SELECT id, vtxos FROM ark_job WHERE status='pending' AND kind='board' AND movement_id IS NULL") printf '3|["v-board"]' ;;
    "SELECT row_to_json(t) FROM (SELECT r.id, w.callback_url"*)
      printf '{"id":11,"callback_url":"http://app/cb?a=1|2","label":"order|42","event_message":"ZXZlbnQ=","address":"ark1receiver","amount_sat":12345,"movement_id":9,"vtxos":"[\\"v-recv\\"]","expected_amount_sat":12345}' ;;
    "SELECT row_to_json(t) FROM (SELECT id, kind, label, callback_url"*)
      printf '{"id":3,"kind":"board","label":"topup-1","callback_url":"http://app/job","txid":"txid-b","movement_id":9,"vtxos":"[\\"v-board\\"]","status":"successful"}' ;;
    "SELECT value FROM cyphernode_props WHERE category='ark' AND property='ark_history_floor'") printf '%s' "${FLOOR:-4}" ;;
    "SELECT value FROM cyphernode_props WHERE category='ark' AND property='ark_history_seen'") printf '%s' "${SEEN:-}" ;;
    "SELECT value FROM cyphernode_props WHERE category='ark' AND property='ark_history_pending'") printf '%s' "${PENDING:-}" ;;
    "SELECT COALESCE(json_agg(DISTINCT movement_id)"*) printf '%s' "${BOUND_JOBS:-[]}" ;;
    *) ;;
  esac
}

sql_params() {
  printf '%s\n' "$@" >> "${SQL_LOG}"
}

notify_web() {
  printf '%s %s\n' "${1}" "${2}" >> "${NOTIFY_LOG}"
  echo '{"curl_code":0,"http_code":200}'
  return 0
}

# Movement 6 is still pending.
barkd_call() {
  printf '%s %s\n' "${1}" "${2}" >> "${SQL_LOG}"
  case "${2}" in
    /history*)
      echo '[{"id":4,"status":"successful","sent_to":[],"received_on":[],"output_vtxos":[]},
             {"id":5,"status":"successful","sent_to":[{"destination":{"type":"ark","value":"ark1payee"},"amount_sat":500}],"received_on":[],"output_vtxos":[]},
             {"id":6,"status":"pending","sent_to":[],"received_on":[],"output_vtxos":[]},
             {"id":8,"status":"successful","sent_to":[{"destination":{"type":"ark","value":"ark1payee"},"amount_sat":500}],"received_on":[],"output_vtxos":[]}]'
      return 0 ;;
    *) return 1 ;;
  esac
}

# --- fixtures ----------------------------------------------------------------

receive='{"id":9,"status":"successful","subsystem":{},"intended_balance_sat":12345,"effective_balance_sat":12345,"offchain_fee_sat":0,
  "sent_to":[],"received_on":[{"destination":{"type":"ark","value":"ark1receiver"},"amount_sat":12345}],
  "input_vtxos":[],"output_vtxos":["v-recv","v-board"],"exited_vtxos":[],"time":{}}'
pending='{"id":10,"status":"pending","sent_to":[],"received_on":[{"destination":{"type":"ark","value":"ark1receiver"},"amount_sat":1}],"output_vtxos":[]}'

fail=0
check() {
  if eval "${2}"; then
    echo "ok   - ${1}"
  else
    echo "FAIL - ${1}"
    fail=1
  fi
}

# --- movements ---------------------------------------------------------------

ark_process_movement "${pending}"
check "pending movements are ignored" "! grep -q 'INSERT INTO ark_receive' '${SQL_LOG}'"

ark_process_movement "${receive}"
check "received movement is recorded once per watch" \
  "[ \"\$(grep -c 'INSERT INTO ark_receive' '${SQL_LOG}')\" -eq 1 ] && grep -q '^movement=9$' '${SQL_LOG}' && grep -q '^address=ark1receiver$' '${SQL_LOG}'"
check "offboard jobs are matched by movement id" \
  "grep -q \"UPDATE ark_job SET status='successful', error=NULL, movement_id=9 WHERE status='pending' AND movement_id=9\" '${SQL_LOG}'"
check "board jobs are matched by their vtxo ids" \
  "grep -q \"UPDATE ark_job SET status='successful', error=NULL, movement_id=9 WHERE id=3 AND status='pending'\" '${SQL_LOG}'"

: > "${SQL_LOG}"
failed='{"id":12,"status":"failed","subsystem":{"name":"bark.board","kind":"board"},"sent_to":[],"received_on":[],"output_vtxos":["v-board"]}'
ark_process_movement "${failed}"
check "failed movement fails its matching board without recording a receive" \
  "grep -q \"UPDATE ark_job SET status='failed', error='Ark movement failed', movement_id=12 WHERE id=3 AND status='pending'\" '${SQL_LOG}' && ! grep -q 'INSERT INTO ark_receive' '${SQL_LOG}'"
check "failed movement fails a matching offboard, allowing its callback" \
  "grep -q \"UPDATE ark_job SET status='failed', error='Ark movement failed', movement_id=12 WHERE status='pending' AND movement_id=12\" '${SQL_LOG}'"

# --- callbacks ---------------------------------------------------------------

ark_do_callbacks
check "receive callback keeps labels and URLs containing the field separator" \
  "grep -q '^http://app/cb?a=1|2 {\"id\":11,\"event\":\"ark_receive\",\"address\":\"ark1receiver\",\"label\":\"order|42\",\"eventMessage\":\"ZXZlbnQ=\",\"amount_sat\":12345,\"expectedAmount\":12345,\"movementId\":9,\"vtxos\":\\[\"v-recv\"\\]}$' '${NOTIFY_LOG}'"
check "job callback names the kind, label, txid and movement id" \
  "grep -q '^http://app/job {\"id\":3,\"event\":\"ark_board\",\"label\":\"topup-1\",\"status\":\"successful\",\"txid\":\"txid-b\",\"movementId\":9,\"vtxos\":\\[\"v-board\"\\],\"error\":null}$' '${NOTIFY_LOG}'"
check "delivered callbacks are marked" \
  "grep -q 'UPDATE ark_receive SET calledback=true' '${SQL_LOG}' && grep -q 'UPDATE ark_job SET calledback=true' '${SQL_LOG}'"

# --- catch-up ----------------------------------------------------------------

: > "${SQL_LOG}"
ark_manage_missed
check "catch-up stops below the oldest pending movement" \
  "grep -q '^floor=5$' '${SQL_LOG}'"
check "catch-up processes final movements above the floor" \
  "grep -q 'movement_id=8' '${SQL_LOG}'"
check "catch-up remembers the highest movement seen and the pending ones" \
  "grep -q '^seen=8$' '${SQL_LOG}' && grep -Fxq 'pending=[6]' '${SQL_LOG}' && [ \"\$(grep -c 'INSERT INTO cyphernode_props' '${SQL_LOG}')\" -eq 1 ]"

# A second catch-up with nothing new must not replay movement 8 (final, already
# seen) while movement 6 is still pending.
: > "${SQL_LOG}"
FLOOR=5 SEEN=8 PENDING='[6]' ark_manage_missed
check "catch-up does not replay movements it already processed" \
  "! grep -q 'movement_id=8' '${SQL_LOG}'"

: > "${SQL_LOG}"
FLOOR=5 SEEN=8 PENDING='[6]' BOUND_JOBS='[4]' ark_manage_missed
check "a pending job bound below the cursor is reconciled" "grep -q 'movement_id=4' '${SQL_LOG}'"

: > "${SQL_LOG}"
check "catch-up leaves the cursor unchanged after a failed movement write" \
  "! FAIL_WRITE=1 ark_manage_missed && ! grep -q 'INSERT INTO cyphernode_props' '${SQL_LOG}'"

# While another catch-up holds the lock, a new one returns without reading history.
: > "${SQL_LOG}"
( flock 7; sleep 2 ) 7>"${ARK_LOCK_DIR}/ark-manage-missed.lock" &
sleep 0.5
check "a busy catch-up lock leaves the request retryable" "! ark_manage_missed"
wait
check "a catch-up already in progress makes a new one skip" \
  "! grep -q 'GET /history' '${SQL_LOG}'"

check "runtime lock open failures propagate from both workers" \
  "! ARK_LOCK_DIR='${ARK_LOCK_DIR}/missing' ark_manage_missed 2>/dev/null && ! ARK_LOCK_DIR='${ARK_LOCK_DIR}/missing' ark_do_callbacks 2>/dev/null"

exit ${fail}
