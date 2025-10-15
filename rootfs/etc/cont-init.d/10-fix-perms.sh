#!/usr/bin/with-contenv bashio
# Ensure cont-init and service scripts are executable inside the container
bashio::log.info "fix-perms: ensuring important scripts are executable"

# Directories to check
dirs=(
  /etc/cont-init.d
  /etc/cont-finish.d
  /etc/services.d
  /usr/local/bin
)

# Make sure directories exist before iterating
for d in "${dirs[@]}"; do
  if [ -d "$d" ]; then
    # Find regular files and mark executable
    find "$d" -type f -print0 | while IFS= read -r -d '' f; do
      if [ ! -x "$f" ]; then
        chmod +x "$f" 2>/dev/null || bashio::log.warning "fix-perms: chmod +x failed for $f"
        bashio::log.info "fix-perms: set executable $f"
      fi
    done
  fi
done

# Also ensure any mount script in /usr/local/bin is executable
if [ -f /usr/local/bin/mount_devices ] && [ ! -x /usr/local/bin/mount_devices ]; then
  chmod +x /usr/local/bin/mount_devices 2>/dev/null || bashio::log.warning "fix-perms: chmod +x failed for /usr/local/bin/mount_devices"
  bashio::log.info "fix-perms: set executable /usr/local/bin/mount_devices"
fi

# Ensure any tailscale service files are executable (if present)
if [ -d /etc/services.d/tailscale ]; then
  find /etc/services.d/tailscale -type f -print0 | while IFS= read -r -d '' f; do
    if [ ! -x "$f" ]; then
      chmod +x "$f" 2>/dev/null || bashio::log.warning "fix-perms: chmod +x failed for $f"
      bashio::log.info "fix-perms: set executable $f"
    fi
  done
fi

bashio::log.info "fix-perms: permission fixup complete"
