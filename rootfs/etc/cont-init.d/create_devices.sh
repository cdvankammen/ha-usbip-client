#!/command/with-contenv bashio
# shellcheck disable=SC1008
bashio::config.require 'log_level'
bashio::log.level "$(bashio::config 'log_level')"

declare server_address
declare bus_id
declare hardware_id
declare script_directory="/usr/local/bin"
declare mount_script="/usr/local/bin/mount_devices"
declare discovery_server_address

discovery_server_address=$(bashio::config 'discovery_server_address')

bashio::log.info ""
bashio::log.info "-----------------------------------------------------------------------"
bashio::log.info "-------------------- Starting USB/IP Client Add-on --------------------"
bashio::log.info "-----------------------------------------------------------------------"
bashio::log.info ""

# Check if the script directory exists and log details
bashio::log.debug "Checking if script directory ${script_directory} exists."
if ! bashio::fs.directory_exists "${script_directory}"; then
    bashio::log.info "Creating script directory at ${script_directory}."
    mkdir -p "${script_directory}" || bashio::exit.nok "Could not create bin folder"
else
    bashio::log.debug "Script directory ${script_directory} already exists."
fi

# Create or clean the mount script
bashio::log.debug "Checking if mount script ${mount_script} exists."
if bashio::fs.file_exists "${mount_script}"; then
    bashio::log.info "Mount script already exists. Removing old script."
    rm "${mount_script}"
fi
bashio::log.info "Creating new mount script at ${mount_script}."
touch "${mount_script}" || bashio::exit.nok "Could not create mount script"
chmod +x "${mount_script}"

# Write initial content to the mount script
echo '#!/command/with-contenv bashio' >"${mount_script}"
echo 'mount -o remount -t sysfs sysfs /sys' >>"${mount_script}"
bashio::log.debug "Mount script initialization complete."

# Discover available devices
bashio::log.info "Discovering devices from server ${discovery_server_address}."
if available_devices=$(usbip list -r "${discovery_server_address}" 2>/dev/null); then
    if [ -z "$available_devices" ]; then
        bashio::log.warning "No devices found on server ${discovery_server_address}."
    else
        bashio::log.info "Available devices from ${discovery_server_address}:"
        echo "$available_devices" | while read -r line; do
            bashio::log.info "$line"
        done
    fi
else
    bashio::log.error "Failed to retrieve device list from server ${discovery_server_address}."
fi

# Loop through configured devices
bashio::log.info "Iterating over configured devices."
for device in $(bashio::config 'devices|keys'); do
    server_address=$(bashio::config "devices[${device}].server_address")
    bus_id=$(bashio::config "devices[${device}].bus_id")
    hardware_id=$(bashio::config "devices[${device}].hardware_id")

    if [ -n "${hardware_id}" ] && [ -z "${bus_id}" ]; then
    bashio::log.info "Resolving bus ID for hardware ID ${hardware_id} from server ${server_address}"
    if device_list=$(usbip list -r "${server_address}" 2>/dev/null); then
        # normalize search term (remove non-hex, lowercase) so "1A86:55D4" and "1a86:55d4" match
        search=$(echo "${hardware_id}" | tr '[:upper:]' '[:lower:]' | sed 's/[^0-9a-f]//g')

        resolved_bus_id=$(echo "${device_list}" | awk -v s="$search" '
            BEGIN { IGNORECASE = 1 }
            # capture device header lines that contain busid like "4-3:" (allow leading spaces and optional "-")
            /^[[:space:]]*[0-9]+([-.0-9])*:/ {
                bid = $1
                sub(/:$/,"",bid)
                next
            }
            {
                # match parenthesized hex like (1a86:55d4)
                if (match($0, /\([0-9a-f]{4}:[0-9a-f]{4}\)/,m)) {
                    hid = tolower(m[0])
                    gsub(/[()]/,"",hid)
                    gsub(/[^0-9a-f]/,"",hid)
                    if (hid == s) { print bid; exit }
                }
                # match USB\VID_xxxx&PID_yyyy\ style
                if (match($0, /USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4}/,m2)) {
                    line = tolower(m2[0])
                    if (match(line, /vid_([0-9a-f]{4})&pid_([0-9a-f]{4})/, parts)) {
                        hid = parts[1] parts[2]
                        if (hid == s) { print bid; exit }
                    }
                }
            }
        ')
        if [ -n "${resolved_bus_id}" ]; then
            bus_id="${resolved_bus_id}"
            bashio::log.info "Resolved hardware ID ${hardware_id} to bus ID ${bus_id}"
        else
            bashio::log.warning "Could not resolve bus ID for hardware ID ${hardware_id} on server ${server_address}"
        fi
    else
        bashio::log.error "Failed to retrieve device list from server ${server_address} while resolving hardware ID ${hardware_id}"
    fi
fi

if [ -z "${bus_id}" ]; then
    bashio::log.warning "Skipping device for server ${server_address}: missing bus ID (and could not resolve from hardware ID)"
    continue
fi


    bashio::log.info "Adding device from server ${server_address} on bus ${bus_id}"

    # Detach any existing attachments
    bashio::log.debug "Detaching device ${bus_id} from server ${server_address} if already attached."
    echo "/usr/sbin/usbip detach -r ${server_address} -b ${bus_id} >/dev/null 2>&1 || true" >>"${mount_script}"

    # Attach the device
    bashio::log.debug "Attaching device ${bus_id} from server ${server_address}."
    echo "/usr/sbin/usbip attach --remote=${server_address} --busid=${bus_id}" >>"${mount_script}"
done

bashio::log.info "Device configuration complete. Ready to attach devices."
