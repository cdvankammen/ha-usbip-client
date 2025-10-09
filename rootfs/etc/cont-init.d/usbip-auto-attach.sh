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

# returns 0 if any local usbip port is already attached to the requested BUSID
local_has_attached() {
  # usbip port prints attached ports; look for the BUSID in that output
  usbip port 2>/dev/null | awk -v busid="$BUSID" '
    BEGIN { found=0 }
    /Port/ { port = $2 }
    /Attached/ { getline; if ($0 ~ busid) found=1 }
    END { exit !found }' >/dev/null 2>&1
}

# get the local port number attached to BUSID (empty if none)
local_attached_portnum() {
  usbip port 2>/dev/null | grep -nF -- "${BUSID}" | awk -F: '{print $1}' | head -n1 || true
}

detach_local_stale() {
  portnum=$(local_attached_portnum)
  if [ -n "${portnum}" ]; then
    echo "${LOG_PREFIX} detaching local port ${portnum}"
    usbip detach -p "${portnum}" 2>/dev/null || true
  fi
}

backoff=1
echo "${LOG_PREFIX} starting watcher (server=${SERVER}, busid=${BUSID})"

# Validate BUSID exists on server before entering main loop; log but continue to loop to catch later
if ! remote_has_busid; then
  echo "${LOG_PREFIX} WARNING: BUSID ${BUSID} not found on server ${SERVER} at startup"
fi

while true; do
  if remote_has_busid; then
    echo "${LOG_PREFIX} remote device present"
    if local_has_attached; then
      portnum=$(local_attached_portnum)
      echo "${LOG_PREFIX} already attached locally on port ${portnum}"
      backoff=1
    else
      echo "${LOG_PREFIX} not attached locally, attempting attach"
      # Double-check usbip port output once more just before attach to avoid race
      if local_has_attached; then
        portnum=$(local_attached_portnum)
        echo "${LOG_PREFIX} attach not needed, already attached on port ${portnum}"
        backoff=1
      else
        if usbip attach -r "${SERVER}" -b "${BUSID}" 2>&1 | tee /dev/stderr | grep -q -E "success|attached|already attached"; then
          # verify attach actually resulted in a local port entry
          if local_has_attached; then
            portnum=$(local_attached_portnum)
            echo "${LOG_PREFIX} attach succeeded, local port ${portnum}"
            backoff=1
          else
            echo "${LOG_PREFIX} attach command returned success but no local port found; will retry"
            sleep "${backoff}"
            backoff=$(( backoff * 2 ))
            if [ "${backoff}" -gt "${MAX_BACKOFF_SEC}" ]; then backoff="${MAX_BACKOFF_SEC}"; fi
          fi
        else
          echo "${LOG_PREFIX} attach failed, retrying with backoff ${backoff}s"
          sleep "${backoff}"
          backoff=$(( backoff * 2 ))
          if [ "${backoff}" -gt "${MAX_BACKOFF_SEC}" ]; then backoff="${MAX_BACKOFF_SEC}"; fi
        fi
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
