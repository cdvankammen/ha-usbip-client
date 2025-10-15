#!/usr/bin/with-contenv bashio
# shellcheck disable=SC1008
bashio::config.require 'log_level'
bashio::log.level "$(bashio::config 'log_level')"

declare server_address
declare bus_id
declare hardware_id
declare script_directory="/usr/local/bin"
declare mount_script="/usr/local/bin/mount_devices"
declare discovery_server_address
declare debug

discovery_server_address=$(bashio::config 'discovery_server_address' || echo "")
debug=$(bashio::config 'debug' || echo "false")

log() { bashio::log.info "$1"; }
log_debug() { [ "${debug}" = "true" ] && bashio::log.debug "$1"; }
log_warn() { bashio::log.warning "$1"; }
log_err() { bashio::log.error "$1"; }

# Validate simple inputs
is_valid_busid() {
    case "$1" in
        '' ) return 1 ;;
        *[!A-Za-z0-9-.:]* ) return 1 ;;
        * ) return 0 ;;
    esac
}

# Safe write helper: append a line to mount script
append_mount() {
    printf '%s\n' "$1" >>"${mount_script}"
}

log ""
log "-----------------------------------------------------------------------"
log "-------------------- Starting USB/IP Client Add-on --------------------"
log "-----------------------------------------------------------------------"
log ""

# Ensure script directory
log "Checking if script directory ${script_directory} exists."
if ! bashio::fs.directory_exists "${script_directory}"; then
    log "Creating script directory at ${script_directory}."
    mkdir -p "${script_directory}" || bashio::exit.nok "Could not create bin folder"
else
    log "Script directory ${script_directory} already exists."
fi

# Recreate mount script
log "Checking if mount script ${mount_script} exists."
if bashio::fs.file_exists "${mount_script}"; then
    log "Mount script already exists. Removing old script."
    rm "${mount_script}"
fi
log "Creating new mount script at ${mount_script}."
cat >"${mount_script}" <<'MOUNT_HEADER'
#!/usr/bin/with-contenv bashio
# Generated mount script for USB/IP attachments (auto-generated)

# Ensure usbip exists
if ! command -v usbip >/dev/null 2>&1; then
    bashio::log.error "usbip tool not found; please install usbip utilities"
    exit 1
fi

# Ensure VHCI module is present (best-effort)
if ! lsmod | grep -q '^vhci_hcd\b'; then
    if ! modprobe vhci_hcd 2>/dev/null; then
        bashio::log.error "vhci_hcd module missing and modprobe failed; usbip attach likely to fail"
    else
        bashio::log.info "Loaded vhci_hcd kernel module"
    fi
else
    bashio::log.info "vhci_hcd kernel module already loaded"
fi

MOUNT_HEADER
chmod +x "${mount_script}"

log "Mount script initialization complete."

# Global device discovery logging (optional, only if discovery_server_address configured)
if [ -n "${discovery_server_address}" ]; then
    log "Discovering devices from server ${discovery_server_address}."
    if device_list=$(usbip list -r "${discovery_server_address}" 2>/dev/null); then
        if [ -z "$device_list" ]; then
            log "No devices found on server ${discovery_server_address}."
        else
            log "Available devices from ${discovery_server_address}:"
            if [ "${debug}" = "true" ]; then
                echo "$device_list" | while read -r line; do bashio::log.info "$line"; done
            else
                echo "$device_list" | grep -E '^[[:space:]]*-' | while read -r line; do bashio::log.info "$line"; done
            fi
        fi
    else
        log_warn "Failed to retrieve device list from server ${discovery_server_address}."
    fi
else
    log_warn "No discovery_server_address configured; skipping global discovery."
fi

# Helper: resolve hardware_id -> bus_id from usbip list output
resolve_busid_from_list() {
    local hw="$1"
    local list="$2"
    local search
    search=$(echo "${hw}" | tr '[:upper:]' '[:lower:]' | sed 's/[^0-9a-f]//g')
    log_debug "Normalized hardware search term: ${search}"

    # Strict match for (vvvv:pppp) or USB VID/PID lines
    local bid
    bid=$(echo "${list}" | awk -v s="${search}" '
        BEGIN { IGNORECASE = 1; bid = "" }
        /^[[:space:]]*[0-9]+([-.0-9])*:/ {
            bid = $1; sub(/:$/,"",bid); next
        }
        {
            if (match($0, /\([0-9a-f]{4}:[0-9a-f]{4}\)/,m)) {
                hid = tolower(m[0]); gsub(/[()]/,"",hid); gsub(/[^0-9a-f]/,"",hid)
                if (hid == s) { print bid; exit }
            }
            if (match($0, /USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4}/,m2)) {
                line = tolower(m2[0])
                if (match(line, /vid_([0-9a-f]{4})&pid_([0-9a-f]{4})/, parts)) {
                    hid = parts[1] parts[2]
                    if (hid == s) { print bid; exit }
                }
            }
        }
    ')
    if [ -n "${bid}" ]; then
        echo "${bid}"
        return 0
    fi

    # Fallback grep-based attempt requiring header line
    local p1 p2
    p1="${search:0:4}"; p2="${search:4}"
    bid=$(echo "${list}" | grep -i -E "(${p1}[: ]*${p2}|VID_${p1}.*PID_${p2})" -B1 | head -n1 | awk '{gsub(/:$/,""); print $1}')
    if [ -n "${bid}" ]; then
        echo "${bid}"
        return 0
    fi

    return 1
}

# Iterate configured devices
log "Iterating over configured devices."
for device in $(bashio::config 'devices | keys'); do
    server_address=$(bashio::config "devices[${device}].server_address")
    bus_id=$(bashio::config "devices[${device}].bus_id")
    hardware_id=$(bashio::config "devices[${device}].hardware_id")

    if [ -z "${server_address}" ]; then
        server_address="${discovery_server_address}"
    fi

    # Resolve hardware_id -> bus_id when needed
    if [ -n "${hardware_id}" ] && [ -z "${bus_id}" ]; then
        log "Resolving bus ID for hardware ID ${hardware_id} from server ${server_address}"
        if device_list=$(usbip list -r "${server_address}" 2>/dev/null); then
            log_debug "Fetched device list from ${server_address}"
            resolved_bus_id=$(resolve_busid_from_list "${hardware_id}" "${device_list}" || true)
            if [ -n "${resolved_bus_id}" ]; then
                bus_id="${resolved_bus_id}"
                log "Resolved hardware ID ${hardware_id} to bus ID ${bus_id}"
            else
                log_warn "Could not resolve bus ID for hardware ID ${hardware_id} on server ${server_address}"
            fi
        else
            log_warn "Failed to retrieve device list from server ${server_address} while resolving hardware ID ${hardware_id}"
        fi
    fi

    if ! is_valid_busid "${bus_id}"; then
        log_warn "Skipping device for server ${server_address}: missing or invalid bus ID"
        continue
    fi

    log "Adding device from server ${server_address} on bus ${bus_id}"

    # Detach any existing attachments (append safe-quoted line)
    append_mount "/usr/sbin/usbip detach -r \"${server_address}\" -b \"${bus_id}\" >/dev/null 2>&1 || true"

    # Append attach block with retries and verification (write verbatim, no outer expansion)
    cat >>"${mount_script}" <<'MOUNT_BLOCK'
bashio::log.info "Attempting to attach device ${bus_id} from server ${server_address}."
attempt=1
max_attempts=3
attached=0
while [ $attempt -le $max_attempts ]; do
    if /usr/sbin/usbip attach -r "${server_address}" -b "${bus_id}" 2>/dev/null; then
        timeout=10
        interval=1
        elapsed=0
        while [ $elapsed -lt $timeout ]; do
            if usbip port | grep -q -- "Port.*: ${server_address}:${bus_id}"; then
                bashio::log.info "Successfully attached device ${bus_id} from ${server_address}"
                attached=1
                break
            fi
            sleep $interval
            elapsed=$((elapsed + interval))
        done
        if [ $attached -eq 1 ]; then
            break
        else
            bashio::log.warning "Attach succeeded but verification failed for ${bus_id}; detaching and retrying"
            /usr/sbin/usbip detach -r "${server_address}" -b "${bus_id}" >/dev/null 2>&1 || true
        fi
    else
        bashio::log.warning "usbip attach failed for ${bus_id} on ${server_address} (attempt $attempt)"
    fi
    attempt=$((attempt + 1))
    backoff=$((2 ** attempt))
    if [ $backoff -gt 30 ]; then backoff=30; fi
    sleep $backoff
done

if [ $attached -ne 1 ]; then
    bashio::log.error "Failed to attach device ${bus_id} from ${server_address} after ${max_attempts} attempts"
fi
MOUNT_BLOCK

done

# Final status check
cat >>"${mount_script}" <<'MOUNT_EOF'
echo ''
bashio::log.info "=== Final USB/IP Connection Status ==="
usbip port || bashio::log.info "usbip port command failed or returned no entries"
echo ''
MOUNT_EOF

log "Device configuration complete. Ready to attach devices."
log "Ensure server-side usbipd is running and devices are exported on the server."
