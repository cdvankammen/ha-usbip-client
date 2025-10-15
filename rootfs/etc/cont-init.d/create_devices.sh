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

discovery_server_address=$(bashio::config 'discovery_server_address')
debug=$(bashio::config 'debug' || echo "false")

bashio::log.info ""
bashio::log.info "-----------------------------------------------------------------------"
bashio::log.info "-------------------- Starting USB/IP Client Add-on --------------------"
bashio::log.info "-----------------------------------------------------------------------"
bashio::log.info ""

# Ensure script directory
bashio::log.info "Checking if script directory ${script_directory} exists."
if ! bashio::fs.directory_exists "${script_directory}"; then
    bashio::log.info "Creating script directory at ${script_directory}."
    mkdir -p "${script_directory}" || bashio::exit.nok "Could not create bin folder"
else
    bashio::log.info "Script directory ${script_directory} already exists."
fi

# Recreate mount script
bashio::log.info "Checking if mount script ${mount_script} exists."
if bashio::fs.file_exists "${mount_script}"; then
    bashio::log.info "Mount script already exists. Removing old script."
    rm "${mount_script}"
fi
bashio::log.info "Creating new mount script at ${mount_script}."
touch "${mount_script}" || bashio::exit.nok "Could not create mount script"
chmod +x "${mount_script}"

# Write header and readiness checks into mount script
cat >"${mount_script}" <<'EOF'
#!/usr/bin/with-contenv bashio
# Generated mount script for USB/IP attachments

# Verify usbip tool exists
if ! command -v usbip >/dev/null 2>&1; then
    bashio::log.error "usbip tool not found; please install usbip-utils"
    exit 1
fi

# Ensure vhci_hcd present
if ! lsmod | grep -q '^vhci_hcd\b'; then
    if ! modprobe vhci_hcd 2>/dev/null; then
        bashio::log.error "Failed to load vhci_hcd module; usbip attach will not work"
        exit 1
    else
        bashio::log.info "Loaded vhci_hcd kernel module"
    fi
else
    bashio::log.info "vhci_hcd kernel module already loaded"
fi

EOF

bashio::log.info "Mount script initialization complete."

# Global device discovery logging
bashio::log.info "Discovering devices from server ${discovery_server_address}."
if device_list=$(usbip list -r "${discovery_server_address}" 2>/dev/null); then
    if [ -z "$device_list" ]; then
        bashio::log.info "No devices found on server ${discovery_server_address}."
    else
        bashio::log.info "Available devices from ${discovery_server_address}:"
        if [ "${debug}" = "true" ]; then
            echo "$device_list" | while read -r line; do
                bashio::log.info "$line"
            done
        else
            # brief summary lines only
            echo "$device_list" | grep -E '^[[:space:]]*-' | while read -r line; do
                bashio::log.info "$line"
            done
        fi
    fi
else
    bashio::log.info "Failed to retrieve device list from server ${discovery_server_address}."
fi

# Iterate configured devices
bashio::log.info "Iterating over configured devices."
for device in $(bashio::config 'devices | keys'); do
    server_address=$(bashio::config "devices[${device}].server_address")
    bus_id=$(bashio::config "devices[${device}].bus_id")
    hardware_id=$(bashio::config "devices[${device}].hardware_id")

    if [ -z "${server_address}" ]; then
        server_address="${discovery_server_address}"
    fi

    # Resolve hardware_id -> bus_id when needed
    if [ -n "${hardware_id}" ] && [ -z "${bus_id}" ]; then
        bashio::log.info "Resolving bus ID for hardware ID ${hardware_id} from server ${server_address}"
        if device_list=$(usbip list -r "${server_address}" 2>/dev/null); then
            if [ "${debug}" = "true" ]; then
                bashio::log.info "Raw device_list from ${server_address}:"
                echo "${device_list}" | while read -r l; do bashio::log.info "RAW: $l"; done
            fi

            # normalize search
            search=$(echo "${hardware_id}" | tr '[:upper:]' '[:lower:]' | sed 's/[^0-9a-f]//g')
            bashio::log.info "Normalized hardware search term: ${search}"

            resolved_bus_id=$(echo "${device_list}" | awk -v s="${search}" '
                BEGIN { IGNORECASE = 1; bid = "" }
                /^[[:space:]]*[0-9]+([-\.0-9])*:/ {
                    bid = $1
                    sub(/:$/,"",bid)
                    next
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

            if [ -z "${resolved_bus_id}" ]; then
                p1="${search:0:4}"
                p2="${search:4}"
                resolved_bus_id=$(echo "${device_list}" \
                  | grep -i -E "(${p1}[: ]*${p2}|VID_${p1}.*PID_${p2})" -B1 \
                  | head -n1 | awk '{gsub(/:$/,""); print $1}')
            fi

            if [ -n "${resolved_bus_id}" ]; then
                bus_id="${resolved_bus_id}"
                bashio::log.info "Resolved hardware ID ${hardware_id} to bus ID ${bus_id}"
            else
                bashio::log.info "Could not resolve bus ID for hardware ID ${hardware_id} on server ${server_address}"
            fi
        else
            bashio::log.info "Failed to retrieve device list from server ${server_address} while resolving hardware ID ${hardware_id}"
        fi
    fi

    if [ -z "${bus_id}" ]; then
        bashio::log.info "Skipping device for server ${server_address}: missing bus ID (and could not resolve from hardware ID)"
        continue
    fi

    bashio::log.info "Adding device from server ${server_address} on bus ${bus_id}"

    # detach any existing attachments
    echo "/usr/sbin/usbip detach -r \"${server_address}\" -b \"${bus_id}\" >/dev/null 2>&1 || true" >>"${mount_script}"

    # Append attach with retries to mount script
    cat >>"${mount_script}" <<EOF
bashio::log.info "Attempting to attach device ${bus_id} from server ${server_address}."
attempt=1
max_attempts=3
attached=0
while [ \$attempt -le \$max_attempts ]; do
    if /usr/sbin/usbip attach -r "${server_address}" -b "${bus_id}" 2>/dev/null; then
        timeout=10
        step=1
        elapsed=0
        while [ \$elapsed -lt \$timeout ]; do
            if usbip port | grep -q -- "Port.*: ${server_address}:${bus_id}"; then
                bashio::log.info "Successfully attached device ${bus_id} from ${server_address}"
                attached=1
                break
            fi
            sleep \$step
            elapsed=\$((elapsed + step))
        done
        if [ \$attached -eq 1 ]; then
            break
        else
            bashio::log.warning "Attach command succeeded but verification failed for ${bus_id}; will retry"
            /usr/sbin/usbip detach -r "${server_address}" -b "${bus_id}" >/dev/null 2>&1 || true
        fi
    else
        bashio::log.warning "usbip attach command failed for ${bus_id} on ${server_address} (attempt \$attempt)"
    fi
    attempt=\$((attempt + 1))
    sleep \$((2 ** attempt))
done

if [ \$attached -ne 1 ]; then
    bashio::log.error "Failed to attach device ${bus_id} from ${server_address} after ${max_attempts} attempts"
fi
EOF

done

# Final status check
cat >>"${mount_script}" <<'EOF'
echo ''
bashio::log.info "=== Final USB/IP Connection Status ==="
usbip port || bashio::log.info "usbip port command failed or returned no entries"
echo ''
EOF

bashio::log.info "Device configuration complete. Ready to attach devices."
bashio::log.info "Ensure server-side usbipd is running and devices are exported on the server."
