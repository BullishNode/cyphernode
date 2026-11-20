#!/bin/sh

. ./trace.sh
. ./sql.sh
. ./ark.sh

# ark_watch: {"address":"ark1...","callbackURL":"...","label":"...","eventMessage":"<base64>","expectedAmount":12345}
#
# Registers a callback for payments received on an Ark address. An Arkoor
# receive is final as soon as barkd records it, so there is one callback per
# received movement. The same address may be watched by several callback URLs.
ark_watchrequest() {
  trace "Entering ark_watchrequest()..."

  local request=${1}
  local address callback_url label event_message expected_amount
  local id inserted returncode

  if ! address=$(ark_request_address "${request}"); then
    echo '{"result":null,"error":{"code":-5,"message":"Invalid Ark address","data":{"event":"ark_watch"}}}'
    return 1
  fi
  callback_url=$(printf '%s' "${request}" | jq -r '.callbackURL // empty')
  label=$(printf '%s' "${request}" | jq -r '.label // empty')
  event_message=$(printf '%s' "${request}" | jq -r '.eventMessage // empty')
  expected_amount=$(printf '%s' "${request}" | jq -r '.expectedAmount // empty')

  if [ -n "${expected_amount}" ]; then
    case "${expected_amount}" in
      *[!0-9]*)
        echo '{"error":{"code":-32602,"message":"expectedAmount must be an integer number of satoshis"}}'
        return 1
        ;;
    esac
  fi

  id=$(sql_params "INSERT INTO ark_watching (address, watching, callback_url, label, event_message, expected_amount_sat)
    VALUES (:'address', true, NULLIF(:'callback', ''), NULLIF(:'label', ''), NULLIF(:'event', ''), NULLIF(:'amount', '')::bigint)
    ON CONFLICT (address, COALESCE(callback_url, '')) DO UPDATE SET
    watching=true, label=EXCLUDED.label, event_message=EXCLUDED.event_message,
    expected_amount_sat=EXCLUDED.expected_amount_sat RETURNING id;" \
    -v "address=${address}" -v "callback=${callback_url}" -v "label=${label}" \
    -v "event=${event_message}" -v "amount=${expected_amount}")
  returncode=$?
  trace_rc ${returncode}

  if [ "${returncode}" -eq 0 ] && [ -n "${id}" ]; then
    inserted=true
  else
    inserted=false
  fi

  jq -cn --argjson id "${id:-null}" --argjson inserted "${inserted}" --arg a "${address}" \
    --arg cb "${callback_url}" --arg lbl "${label}" --arg em "${event_message}" --arg ea "${expected_amount}" \
    '{id: $id, event: "ark_watch", inserted: $inserted, address: $a,
      callbackURL: (if $cb == "" then null else $cb end),
      "label": (if $lbl == "" then null else $lbl end),
      eventMessage: (if $em == "" then null else $em end),
      expectedAmount: (if $ea == "" then null else ($ea | tonumber) end)}'

  return ${returncode}
}

# ark_unwatch: by id {"id":12}, or by address with optional callbackURL
ark_unwatchrequest() {
  trace "Entering ark_unwatchrequest()..."

  local watchid=${1}
  local address=${2}
  local callback_url=${3}
  local returncode

  if [ -n "${watchid}" ] && [ "${watchid}" != "null" ]; then
    case "${watchid}" in
      *[!0-9]*)
        echo '{"error":{"code":-32602,"message":"id must be an integer"}}'
        return 1
        ;;
    esac
    sql_params "UPDATE ark_watching SET watching=false WHERE id=:'id'::integer;" -v "id=${watchid}" > /dev/null
    returncode=$?
    jq -cn --argjson id "${watchid}" '{event: "ark_unwatch", id: $id}'
    return ${returncode}
  fi

  if ! ark_is_address "${address}"; then
    echo '{"error":{"code":-5,"message":"Invalid Ark address"}}'
    return 1
  fi
  [ "${callback_url}" != "null" ] || callback_url=
  sql_params "UPDATE ark_watching SET watching=false WHERE address=:'address'
    AND (NULLIF(:'callback', '') IS NULL OR callback_url=:'callback');" \
    -v "address=${address}" -v "callback=${callback_url}" > /dev/null
  returncode=$?
  jq -cn --arg a "${address}" --arg cb "${callback_url}" \
    '{event: "ark_unwatch", address: $a, callbackURL: (if $cb == "" or $cb == "null" then null else $cb end)}'
  return ${returncode}
}

ark_getactivewatches() {
  trace "Entering ark_getactivewatches()..."

  local watches returncode
  watches=$(sql_json "SELECT id, address, callback_url, label, event_message, expected_amount_sat, inserted_ts FROM ark_watching WHERE watching ORDER BY id")
  returncode=$?
  printf '%s' "${watches}" | jq -cs '
    {watches: [ .[] |
      {id: .id, address: .address, callbackURL: .callback_url, "label": .label,
       eventMessage: .event_message, expectedAmount: .expected_amount_sat, inserted: .inserted_ts} ]}'
  return ${returncode}
}
