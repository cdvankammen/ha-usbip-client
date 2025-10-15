#!/usr/bin/with-contenv bashio
# Install Tailscale binaries on first run if missing
# Ensure add-on data-backed folder exists and map it to /var/lib/tailscale
mkdir -p /data/tailscale
chown root:root /data/tailscale
chmod 700 /data/tailscale
ln -sfn /data/tailscale /var/lib/tailscale



bashio::log.info "Checking Tailscale installation"

if command -v tailscaled >/dev/null 2>&1 && command -v tailscale >/dev/null 2>&1; then
  bashio::log.info "Tailscale already installed"
  exit 0
fi

TMPDIR=/tmp/tailscale-install
mkdir -p "${TMPDIR}" && cd "${TMPDIR}" || exit 1

ARCH=$(uname -m)
bashio::log.info "Downloading tailscale for ${ARCH}"
if ! wget -q "https://pkgs.tailscale.com/stable/tailscale_${ARCH}.tgz"; then
  bashio::log.error "Failed to download tailscale archive"
  exit 1
fi

tar -xzf tailscale_*.tgz || { bashio::log.error "Failed to extract tailscale"; exit 1; }
cd tailscale_* || { bashio::log.error "Missing extracted folder"; exit 1; }

bashio::log.info "Installing tailscale binaries"
cp -a tailscale tailscaled /usr/bin/ || { bashio::log.error "Failed to copy binaries"; exit 1; }
chmod +x /usr/bin/tailscale /usr/bin/tailscaled

# Prepare persistent state directory
mkdir -p /var/lib/tailscale
chown root:root /var/lib/tailscale
chmod 700 /var/lib/tailscale

# Cleanup
cd /
rm -rf "${TMPDIR}"
bashio::log.info "Tailscale install complete"
