#!/usr/bin/with-contenv bashio
# Try to bring Tailscale up non-interactively using an auth key or saved state

TS_AUTHKEY="$(bashio::config 'tailscale.auth_key' || echo "")"
TS_HOSTNAME="$(bashio::config 'tailscale.hostname' || echo "")"

# Wait for tailscaled to become responsive (bounded)
tries=0
while ! /usr/bin/tailscale status >/dev/null 2>&1 && [ $tries -lt 15 ]; do
  sleep 1
  tries=$((tries + 1))
done

if /usr/bin/tailscale status >/dev/null 2>&1; then
  bashio::log.info "Tailscale already up"
  exit 0
fi

if [ -n "$TS_AUTHKEY" ]; then
  CMD="/usr/bin/tailscale up --authkey=${TS_AUTHKEY} --accept-dns=false"
  [ -n "$TS_HOSTNAME" ] && CMD="${CMD} --hostname=${TS_HOSTNAME}"
  bashio::log.info "Bringing Tailscale up non-interactively"
  if $CMD; then
    bashio::log.info "tailscale up succeeded"
  else
    bashio::log.error "tailscale up failed"
  fi
else
  bashio::log.warning "No Tailscale auth key provided; if this is first install, provide auth key or run 'tailscale up' manually"
fi
