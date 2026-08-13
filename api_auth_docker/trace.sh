#!/bin/sh

trace()
{
  case "${TRACING:-}" in
    1|true|TRUE|yes|YES|on|ON)
      local str="[$(date +%Y-%m-%dT%H:%M:%S%z)] $$ $*"
      echo "${str}" 1>&2
      echo "${str}" >> "${GATEKEEPER_LOG_PATH:-/cnlogs/gatekeeper.log}"
      ;;
  esac
  return 0
}
