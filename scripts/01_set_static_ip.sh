#!/usr/bin/env bash
# scripts/01_set_static_ip.sh — set the wireless connection to a static IPv4.
#
# Required because the router's DMZ rule needs a fixed target. The DHCP-assigned
# address can change across leases.
#
# What this does:
#   1. Auto-detects the active wireless NetworkManager profile and its interface.
#   2. Auto-detects the current default gateway (from the live default route).
#   3. STRICT validation up front (fails before touching anything):
#        - target IP is well-formed IPv4, no network/broadcast/loopback values
#        - exactly one active wireless connection (refuses to guess between several)
#        - wireless interface exists, link is UP, carrier is present
#        - default-route gateway is on the wireless interface (not some other route)
#        - target IP is on the same /24 as the gateway
#        - target IP does not respond to ping (not in use by another device)
#   4. Switches the wireless profile from DHCP to manual with the target IP.
#   5. Cycles the connection (down + up).
#   6. Verifies internet reachability; rolls back to DHCP automatically on failure.
#
# Usage:
#   sudo bash scripts/01_set_static_ip.sh                # defaults to 10.0.0.200
#   sudo bash scripts/01_set_static_ip.sh <ipv4-address> # explicit
#
# Examples:
#   sudo bash scripts/01_set_static_ip.sh                # 10.0.0.200
#   sudo bash scripts/01_set_static_ip.sh 10.0.0.199     # second box on same LAN
#
# After this script succeeds, you must update your router's DMZ target on the
# router's admin UI to match the new IP. The script cannot do that for you.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

# -----------------------------------------------------------------------------
# Argument handling (defaults to 10.0.0.200)
# -----------------------------------------------------------------------------

DEFAULT_IP=10.0.0.200

if [ $# -gt 1 ]; then
    die "usage: sudo bash $0 [<ipv4-address>]   (default: $DEFAULT_IP)"
fi
TARGET_IP="${1:-$DEFAULT_IP}"

# -----------------------------------------------------------------------------
# Precondition validation — strict, all up front, before any change is made.
# -----------------------------------------------------------------------------

require_root
require_command nmcli
require_command ip
require_command ping

# --- 1. Validate the target IPv4 address itself ---

if ! [[ "$TARGET_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    die "invalid IPv4 address: '$TARGET_IP' (not four dotted octets)"
fi
IFS='.' read -ra OCTETS <<< "$TARGET_IP"
for o in "${OCTETS[@]}"; do
    [ "$o" -ge 0 ] && [ "$o" -le 255 ] || die "invalid IPv4 octet '$o' in '$TARGET_IP' (out of range 0-255)"
done
# Reject obviously-invalid host addresses.
[ "${OCTETS[0]}" -ne 0 ]   || die "invalid IPv4 '$TARGET_IP' (first octet 0 = network address)"
[ "${OCTETS[0]}" -ne 127 ] || die "invalid IPv4 '$TARGET_IP' (loopback range 127.0.0.0/8)"
[ "${OCTETS[3]}" -ne 0 ]   || die "invalid IPv4 '$TARGET_IP' (last octet 0 = network address)"
[ "${OCTETS[3]}" -ne 255 ] || die "invalid IPv4 '$TARGET_IP' (last octet 255 = broadcast)"

info "target IP: $TARGET_IP"

# --- 2. NetworkManager must be active ---

systemctl is-active --quiet NetworkManager \
    || die "NetworkManager is not running — this script only manages NetworkManager profiles"

# --- 3. Find EXACTLY ONE active wireless connection. ---
# We refuse to guess if multiple are active, and we refuse to proceed if none are.

mapfile -t WIFI_CONS < <(nmcli -t -f NAME,TYPE,STATE connection show --active \
    | awk -F: '$2 ~ /wireless/ && $3 == "activated" {print $1}')

if [ "${#WIFI_CONS[@]}" -eq 0 ]; then
    die "no active wireless connection found — connect to Wi-Fi first"
fi
if [ "${#WIFI_CONS[@]}" -gt 1 ]; then
    die "multiple active wireless connections found ('${WIFI_CONS[*]}') — refuse to guess which to modify"
fi
WIFI_CON="${WIFI_CONS[0]}"
info "wireless connection profile: $WIFI_CON"

# --- 4. Resolve the device name for that connection ---

WIFI_IFACE="$(nmcli -t -f GENERAL.DEVICES connection show "$WIFI_CON" \
    | head -1 | cut -d: -f2)"
[ -n "$WIFI_IFACE" ] \
    || die "could not resolve interface name for connection '$WIFI_CON' (nmcli returned empty GENERAL.DEVICES)"
info "wireless interface: $WIFI_IFACE"

# --- 5. Validate the interface is real and the link is up with carrier ---

if ! ip -br link show "$WIFI_IFACE" >/dev/null 2>&1; then
    die "interface '$WIFI_IFACE' does not exist (resolved from connection '$WIFI_CON')"
fi
LINK_STATE="$(ip -br link show "$WIFI_IFACE" | awk '{print $2}')"
[ "$LINK_STATE" = "UP" ] \
    || die "interface '$WIFI_IFACE' link state is '$LINK_STATE', expected 'UP'"
CARRIER_FILE="/sys/class/net/$WIFI_IFACE/carrier"
[ -r "$CARRIER_FILE" ] \
    || die "cannot read $CARRIER_FILE — interface may have just disappeared"
CARRIER="$(cat "$CARRIER_FILE")"
[ "$CARRIER" = "1" ] \
    || die "interface '$WIFI_IFACE' has no carrier (Wi-Fi not associated with an AP)"

# --- 6. Validate the default route is on this wireless interface ---

CURRENT_GW="$(ip route show default | awk '/^default/ {print $3; exit}')"
[ -n "$CURRENT_GW" ] \
    || die "no default gateway visible in 'ip route show default' — Wi-Fi must be online"
GW_IFACE="$(ip route show default | awk '/^default/ {print $5; exit}')"
[ "$GW_IFACE" = "$WIFI_IFACE" ] \
    || die "default-route gateway is on '$GW_IFACE', not the wireless interface '$WIFI_IFACE' — multi-NIC routing is unsupported"
info "current default gateway: $CURRENT_GW (on $WIFI_IFACE)"

# --- 7. Validate the target IP is on the same /24 as the gateway ---

gw_prefix="$(echo "$CURRENT_GW" | awk -F. '{print $1"."$2"."$3}')"
target_prefix="$(echo "$TARGET_IP" | awk -F. '{print $1"."$2"."$3}')"
[ "$gw_prefix" = "$target_prefix" ] \
    || die "target IP '$TARGET_IP' is not on the same /24 as gateway '$CURRENT_GW'"

# --- 8. Detect the current address; idempotency short-circuit ---

CURRENT_IP="$(ip -4 -o addr show "$WIFI_IFACE" | awk '{print $4}' | cut -d/ -f1 | head -1)"
info "current IP on $WIFI_IFACE: ${CURRENT_IP:-<none>}"

if [ "${CURRENT_IP:-}" = "$TARGET_IP" ]; then
    info "already at $TARGET_IP — nothing to do"
    exit 0
fi

# --- 9. Verify the target IP is not in use by another device on the LAN ---

if ping -c 1 -W 1 "$TARGET_IP" >/dev/null 2>&1; then
    die "$TARGET_IP responds to ping — another device on the LAN is already using it"
fi
info "$TARGET_IP is unused — proceeding"

# -----------------------------------------------------------------------------
# Rollback helper (defined before apply, called from any post-apply failure)
# -----------------------------------------------------------------------------

rollback_to_dhcp() {
    warn "rolling back to DHCP..."
    nmcli connection modify "$WIFI_CON" ipv4.method auto \
                                        ipv4.addresses "" \
                                        ipv4.gateway   "" \
                                        ipv4.dns       "" || true
    nmcli connection down "$WIFI_CON" >/dev/null 2>&1 || true
    sleep 2
    nmcli connection up   "$WIFI_CON" >/dev/null 2>&1 || true
    warn "rollback complete — interface is back on DHCP"
}

# -----------------------------------------------------------------------------
# Apply — modify the profile, cycle the connection, with rollback on failure.
# -----------------------------------------------------------------------------

section "applying static IP $TARGET_IP/24 via $CURRENT_GW on $WIFI_IFACE"
nmcli connection modify "$WIFI_CON" \
    ipv4.method manual \
    ipv4.addresses "$TARGET_IP/24" \
    ipv4.gateway  "$CURRENT_GW" \
    ipv4.dns      "$CURRENT_GW 8.8.8.8"

nmcli connection down "$WIFI_CON" >/dev/null 2>&1 || true
sleep 2
if ! nmcli connection up "$WIFI_CON" >/dev/null 2>&1; then
    rollback_to_dhcp
    die "failed to bring '$WIFI_CON' up with the new static config"
fi

# -----------------------------------------------------------------------------
# Post-condition verification — IP took, internet reachable.
# -----------------------------------------------------------------------------

section "verification"

NEW_IP="$(ip -4 -o addr show "$WIFI_IFACE" | awk '{print $4}' | cut -d/ -f1 | head -1)"
info "new IP on $WIFI_IFACE: ${NEW_IP:-<none>}"
if [ "${NEW_IP:-}" != "$TARGET_IP" ]; then
    rollback_to_dhcp
    die "static IP did not take (expected $TARGET_IP, got '${NEW_IP:-<none>}')"
fi

# Verify outbound internet via two well-known IPv4 endpoints. We avoid DNS so
# a DNS hiccup doesn't masquerade as a connectivity failure.
if ping -c 2 -W 3 1.1.1.1 >/dev/null 2>&1 || ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1; then
    info "internet reachable — OK"
else
    rollback_to_dhcp
    die "internet unreachable from $TARGET_IP — check gateway and DNS"
fi

section "success"
info "static IP $TARGET_IP applied via gateway $CURRENT_GW on $WIFI_IFACE."
info "now update the router's DMZ target on the router admin UI to: $TARGET_IP"
