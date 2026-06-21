#!/usr/bin/env bash
set -euo pipefail

WORKDIR="/var/lib/tailscale-ru-routes"
CONF_DIR="/etc/tailscale-ru-routes"

ASN_FILE="$CONF_DIR/asns.txt"
ASN_DENYLIST_FILE="$CONF_DIR/asn-denylist.txt"
HOST_FILE="$CONF_DIR/hosts.txt"

ASN_GENERATED_FILE="$WORKDIR/generated-asns.txt"
ASN_EFFECTIVE_FILE="$WORKDIR/effective-asns.txt"
ROUTES_FILE="$WORKDIR/routes.txt"
OLD_ROUTES_FILE="$WORKDIR/routes.old.txt"

LOG_TAG="ts-ru-routes"

MIN_PREFIX_V4=8
MAX_PREFIX_V4=32
MAX_ROUTES=500

mkdir -p "$WORKDIR"

tmp_ips="$(mktemp)"
tmp_asns="$(mktemp)"
tmp_all_asns="$(mktemp)"
tmp_raw_routes="$(mktemp)"
tmp_routes="$(mktemp)"
trap 'rm -f "$tmp_ips" "$tmp_asns" "$tmp_all_asns" "$tmp_raw_routes" "$tmp_routes"' EXIT

log() {
  logger -t "$LOG_TAG" "$*"
  echo "$*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log "Missing required command: $1"
    exit 1
  }
}

require_cmd bgpq4
require_cmd dig
require_cmd python3
require_cmd tailscale

normalise_asn_file() {
  local file="$1"

  [[ -f "$file" ]] || return 0

  awk '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*$/ {next}
    {
      asn=$1
      gsub(/[[:space:]]/, "", asn)
      if (asn ~ /^AS[0-9]+$/) print asn
      else if (asn ~ /^[0-9]+$/) print "AS" asn
    }
  ' "$file"
}

reverse_ipv4() {
  awk -F. '{print $4"."$3"."$2"."$1}'
}

ip_to_asns_cymru_dns() {
  local ip="$1"
  local reversed
  reversed="$(echo "$ip" | reverse_ipv4)"

  dig +short TXT "${reversed}.origin.asn.cymru.com" \
    | tr -d '"' \
    | awk -F'|' '{print $1}' \
    | tr ' ' '\n' \
    | grep -E '^[0-9]+$' \
    | sed 's/^/AS/' \
    | sort -u || true
}

log "Starting route update"

# 1. Resolve hosts to IPv4
if [[ -f "$HOST_FILE" ]]; then
  while read -r host _comment; do
    [[ -z "${host:-}" ]] && continue
    [[ "$host" =~ ^# ]] && continue

    log "Resolving host: $host"

    dig +short A "$host" \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
      >> "$tmp_ips" || true
  done < "$HOST_FILE"
else
  log "Host file not found: $HOST_FILE"
fi

sort -u "$tmp_ips" -o "$tmp_ips"

# 2. Resolve IPs to ASNs via Team Cymru DNS
while read -r ip; do
  [[ -z "${ip:-}" ]] && continue

  asns="$(ip_to_asns_cymru_dns "$ip")"

  if [[ -n "$asns" ]]; then
    log "Resolved $ip -> $(echo "$asns" | paste -sd, -)"
    echo "$asns" >> "$tmp_asns"
  else
    log "WARN: Could not resolve ASN for $ip"
  fi
done < "$tmp_ips"

sort -u "$tmp_asns" > "$ASN_GENERATED_FILE"

# 3. Merge static and generated ASNs
{
  normalise_asn_file "$ASN_FILE"
  cat "$ASN_GENERATED_FILE"
} | sort -u > "$tmp_all_asns"

# 4. Apply denylist
if [[ -f "$ASN_DENYLIST_FILE" ]]; then
  normalise_asn_file "$ASN_DENYLIST_FILE" | sort -u > "$WORKDIR/denylist.normalised.txt"

  grep -vxFf "$WORKDIR/denylist.normalised.txt" "$tmp_all_asns" \
    > "$ASN_EFFECTIVE_FILE" || true
else
  cp "$tmp_all_asns" "$ASN_EFFECTIVE_FILE"
fi

effective_asn_count="$(wc -l < "$ASN_EFFECTIVE_FILE" | tr -d ' ')"

if [[ "$effective_asn_count" -eq 0 ]]; then
  log "No ASNs available. Refusing to change Tailscale routes."
  exit 1
fi

log "Effective ASN count: $effective_asn_count"

# 5. Expand ASNs into IPv4 prefixes
while read -r asn; do
  [[ -z "${asn:-}" ]] && continue

  log "Generating prefixes for $asn"

  bgpq4 -4 -A -F "%n/%l\n" "$asn" >> "$tmp_raw_routes" || {
    log "WARN: bgpq4 failed for $asn"
  }
done < "$ASN_EFFECTIVE_FILE"

# 6. Validate, deduplicate and aggregate
python3 - "$tmp_raw_routes" "$MIN_PREFIX_V4" "$MAX_PREFIX_V4" > "$tmp_routes" <<'PY'
import ipaddress
import sys

raw_file = sys.argv[1]
min_prefix = int(sys.argv[2])
max_prefix = int(sys.argv[3])

nets = []

with open(raw_file, "r", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith("#"):
            continue

        try:
            net = ipaddress.ip_network(line, strict=False)
        except ValueError:
            continue

        if net.version != 4:
            continue

        if net.prefixlen < min_prefix or net.prefixlen > max_prefix:
            continue

        nets.append(net)

collapsed = sorted(
    ipaddress.collapse_addresses(nets),
    key=lambda n: (int(n.network_address), n.prefixlen)
)

for net in collapsed:
    print(net)
PY

route_count="$(wc -l < "$tmp_routes" | tr -d ' ')"

if [[ "$route_count" -eq 0 ]]; then
  log "No routes generated. Refusing to clear existing Tailscale routes."
  exit 1
fi

if [[ "$route_count" -gt "$MAX_ROUTES" ]]; then
  log "Too many routes: $route_count > $MAX_ROUTES. Refusing to apply."
  log "Check $ASN_EFFECTIVE_FILE and deny large operator ASNs."
  exit 1
fi

cp "$tmp_routes" "$ROUTES_FILE"

if [[ -f "$OLD_ROUTES_FILE" ]] && cmp -s "$ROUTES_FILE" "$OLD_ROUTES_FILE"; then
  log "No route changes. Route count: $route_count"
  exit 0
fi

routes_csv="$(paste -sd, "$ROUTES_FILE")"

log "Publishing $route_count routes to Tailscale"

tailscale set --advertise-routes="$routes_csv"

cp "$ROUTES_FILE" "$OLD_ROUTES_FILE"

log "Done. Published route count: $route_count"
