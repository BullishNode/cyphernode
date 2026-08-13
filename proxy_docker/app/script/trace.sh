#!/bin/sh

trace_enabled() {
  case "${TRACING:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

trace() {
  if trace_enabled; then
    local event
    event=$(printf '%s' "${1}" | sed -n 's/^\(\[[A-Za-z0-9_. -]*\]\).*/\1/p')
    if [ -z "${event}" ]; then
      event="proxy event"
    fi
    local str="$(date -u '+%Y-%m-%dT%H:%M:%S.%3N') $$ ${event}"
    echo "${str}" 1>&2
    echo "${str}" >> "${PROXY_LOG_PATH:-/cnlogs/proxy.log}"
  fi
}

trace_rc() {
  if trace_enabled; then
    local str="$(date -u '+%Y-%m-%dT%H:%M:%S.%3N') $$ Last return code: ${1}"
    echo "${str}" 1>&2
    echo "${str}" >> "${PROXY_LOG_PATH:-/cnlogs/proxy.log}"
  fi
}
