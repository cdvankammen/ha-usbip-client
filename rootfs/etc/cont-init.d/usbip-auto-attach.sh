#!/usr/bin/env bash
# watcher script placed inside rootfs/etc/cont-init.d so no new folders are required
set -euo pipefail

# runtime values: Supervisor exposes add-on options in /data/options.json
SERVER="${SERVER:-}"
BUSID="${BUSID:-}"
if [ -f /data/options.json ]; then
  SERVER="${SERVER:-$(jq -r '.discovery_server_address // empty' /data/options.json)}"
  BUSID="${BUSID:-$(jq -r '.devices[0].bus_id // empty' /data/options.json)}"
fi

# sensible defaults if nothing provided
SERVER="${SERVER:-192.168.1.100}"
BUSID="${BUSID:-1-1.2}"

CHECK_INTERVAL_SEC="${CHECK_INTERVAL_SEC:-5}"
MAX_BACKOFF_SEC="${MAX_BACKOFF_SEC:-300}"
LOG_PREFIX="[usbip-auto-attach ${BUSID}@${SERVER}]"

remote_has_busid() {
  usbip list -r "${SERVER}" 2>/dev/null | grep -F -- "${BUSID}" >/dev/null 2>&1
}

local_has_attached() {
  usbip port 2>/dev/null | grep -F -- "${BUSID}" >/dev/null 2>&1
}

detach_local_stale() {
  portnum=$(usbip port 2>/dev/null | grep -nF -- "${BUSID}" | awk -F: '{print $1}' | head -n1 || true)
  if [ -n "${portnum}" ]; then
    echo "${LOG_PREFIX} detaching local port ${portnum}"
    usbip detach -p "${portnum}" 2>/dev/null || true
  fi
}

backoff=1
echo "${LOG_PREFIX} starting watcher (server=${SERVER}, busid=${BUSID})"
while true; do
  if remote_has_busid; then
    echo "${LOG_PREFIX} remote device present"
    if local_has_attached; then
      echo "${LOG_PREFIX} already attached locally"
      backoff=1
    else
      echo "${LOG_PREFIX} attempting attach"
      if usbip attach -r "${SERVER}" -b "${BUSID}" 2>&1 | tee /dev/stderr | grep -q -E "success|attached|already attached"; then
        echo "${LOG_PREFIX} attach succeeded"
        backoff=1
      else
        echo "${LOG_PREFIX} attach failed, retrying with backoff ${backoff}s"
        sleep "${backoff}"
        backoff=$(( backoff * 2 ))
        if [ "${backoff}" -gt "${MAX_BACKOFF_SEC}" ]; then backoff="${MAX_BACKOFF_SEC}"; fi
      fi
    fi
  else
    echo "${LOG_PREFIX} remote device not present"
    if local_has_attached; then
      echo "${LOG_PREFIX} local stale attachment detected"
      detach_local_stale
    fi
    backoff=1
  fi

  sleep "${CHECK_INTERVAL_SEC}"
done
