#!/bin/sh

trace_enabled() {
  case "${TRACING:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

trace() {
  if trace_enabled; then
    local str="$(date -u '+%Y-%m-%dT%H:%M:%S.%3N') $$ ${1}"
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
