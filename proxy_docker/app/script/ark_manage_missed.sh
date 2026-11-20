#!/bin/sh

. ./trace.sh
. ./sql.sh
. ./ark_callbacks.sh

# Runs from proxycron. Re-reads barkd's history so nothing is lost when the
# proxy was down or the notification stream lagged, then posts pending
# callbacks.
#
# The history floor is the highest movement id below which every movement is
# final. Above the floor, a movement is processed once when it is first seen
# final: either its id is above the highest id seen so far, or it was still
# pending at the previous run. A movement that stays pending therefore holds
# the floor without making every later run replay the movements after it.
#
# One run at a time: proxycron, the notification stream and the request
# handler can all start it, and a run can outlast the cron interval.
ark_manage_missed() {
  trace "Entering ark_manage_missed()..."
  (
  local history floor seen pending new_floor new_seen new_pending movements movement jobs

  if ! flock --nonblock 7; then
    trace "[ark_manage_missed] could not get the lock"
    exit 1
  fi

  # Unpaid Lightning invoices past their expiry get no callback.
  sql "UPDATE ark_ln_invoice SET status='expired' WHERE status='unpaid' AND expires_at IS NOT NULL AND expires_at < EXTRACT(EPOCH FROM NOW())" > /dev/null || exit 1

  if ! history=$(ark_barkd_read /history); then
    trace "[ark_manage_missed] barkd history unavailable"
    ark_do_callbacks
    exit 1
  fi
  printf '%s' "${history}" | jq -e 'type == "array"' > /dev/null || exit 1

  floor=$(sql "SELECT value FROM cyphernode_props WHERE category='ark' AND property='ark_history_floor'") || exit 1
  floor=${floor:-0}
  seen=$(sql "SELECT value FROM cyphernode_props WHERE category='ark' AND property='ark_history_seen'") || exit 1
  seen=${seen:-${floor}}
  pending=$(sql "SELECT value FROM cyphernode_props WHERE category='ark' AND property='ark_history_pending'") || exit 1
  pending=${pending:-[]}

  movements=$(printf '%s' "${history}" | jq -c --argjson f "${floor}" --argjson s "${seen}" --argjson p "${pending}" '
    .[] | select((.status == "successful" or .status == "failed") and .id > $f)
    | select(.id > $s or (.id as $i | $p | any(.[]; . == $i)))') || exit 1
  local IFS="
"
  for movement in ${movements}; do
    ark_process_movement "${movement}" || exit 1
  done

  # A movement may have become final before the caller bound its job id.
  # Reconcile those pending jobs even when their movement is below the floor.
  jobs=$(sql "SELECT COALESCE(json_agg(DISTINCT movement_id), '[]') FROM ark_job WHERE status='pending' AND movement_id IS NOT NULL") || exit 1
  if [ "${jobs}" != '[]' ]; then
    movements=$(printf '%s' "${history}" | jq -c --argjson jobs "${jobs}" '
      .[] | select(.status == "successful" or .status == "failed")
      | select(.id as $i | $jobs | any(.[]; . == $i))') || exit 1
    for movement in ${movements}; do
      ark_process_movement "${movement}" || exit 1
    done
  fi

  new_floor=$(printf '%s' "${history}" | jq --argjson f "${floor}" '
    ([.[] | select(.status == "pending") | .id] | min) as $p
    | (if $p then $p - 1 else ([.[].id] | max // 0) end) | if . > $f then . else $f end') || exit 1
  new_seen=$(printf '%s' "${history}" | jq --argjson s "${seen}" '[.[].id] | max // 0 | if . > $s then . else $s end') || exit 1
  new_pending=$(printf '%s' "${history}" | jq -c '[.[] | select(.status == "pending") | .id]') || exit 1
  if [ "${new_floor}" != "${floor}" ] || [ "${new_seen}" != "${seen}" ] || [ "${new_pending}" != "${pending}" ]; then
    sql_params "INSERT INTO cyphernode_props (category, property, value) VALUES
      ('ark', 'ark_history_floor', :'floor'), ('ark', 'ark_history_seen', :'seen'),
      ('ark', 'ark_history_pending', :'pending') ON CONFLICT (category, property) DO UPDATE SET value=EXCLUDED.value;" \
      -v "floor=${new_floor}" -v "seen=${new_seen}" -v "pending=${new_pending}" > /dev/null || exit 1
  fi

  ark_do_callbacks || trace "[ark_manage_missed] callback delivery remains pending"
  exit 0
  ) 7>"${ARK_LOCK_DIR:-${DB_PATH:-/tmp}}/ark-manage-missed.lock"
}
