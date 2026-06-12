#!/usr/bin/env bash
# scripts/12_set_static_ip.sh — pin this box to a static IPv4 on Ethernet and
# disable Wi-Fi, so it lives on the wire at a fixed address.
#
# Required because the router's DMZ rule needs a fixed target. A DHCP-assigned
# address can change across leases; the DMZ must point at an address that never
# moves, carried by the interface the box actually serves traffic on (Ethernet).
#
# Designed for the specific shape this project lives in:
#   - Single host with one hardware Ethernet NIC, currently on DHCP from the
#     router, plus (optionally) one Wi-Fi card.
#   - Owner wants the box to live on Ethernet at a fixed static IPv4, with Wi-Fi
#     disabled but recoverable on demand.
#
# What this does (in order):
#   1. Exhaustive pre-flight validation — refuses to run unless the system is in
#      the expected shape. No auto-repair, no guessing across multiple candidates.
#   2. If Ethernet is already at the target static IP, the apply is skipped
#      (idempotent). Otherwise the Ethernet profile is switched DHCP -> manual:
#        - addresses=<target>/24
#        - gateway=<auto-detected from the live default route on Ethernet>
#        - dns=<gateway> 8.8.8.8
#      Ethernet is cycled to claim the address. If Wi-Fi is still up it carries
#      traffic during the brief Ethernet-down window.
#   3. Validates end-to-end on Ethernet: target IP held only by Ethernet, kernel
#      routes outbound via Ethernet, gateway pings via Ethernet, internet pings
#      via Ethernet. Any failure rolls the Ethernet profile back to DHCP.
#   4. Disables the Wi-Fi radio (`nmcli radio wifi off`). Persists across reboots
#      via /var/lib/NetworkManager/NetworkManager.state. Reversible at any time
#      with: sudo nmcli radio wifi on
#
# Failure semantics:
#   - Anything in steps 1-3 fails -> automatic rollback to the original state
#     (Ethernet DHCP, Wi-Fi untouched). Script exits non-zero.
#   - Once step 3 has passed, the static IP is *committed*. Step 4 is best-effort:
#     anomalies are reported as warnings; the script does not exit non-zero after
#     commit, on the principle that the box is now in a working state and a
#     partial failure of the radio toggle should not look like a setup failure.
#
# Usage:
#   sudo bash scripts/12_set_static_ip.sh                # defaults to 10.0.0.200
#   sudo bash scripts/12_set_static_ip.sh <ipv4-address> # explicit
#
# Examples:
#   sudo bash scripts/12_set_static_ip.sh                # 10.0.0.200
#   sudo bash scripts/12_set_static_ip.sh 10.0.0.199     # second box on same LAN
#
# After this script succeeds, you must update your router's DMZ target on the
# router's admin UI to match the new IP. The script cannot do that for you.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

# common.sh enables `set -Eeuo pipefail`. We disable -E here so the ERR trap
# below does NOT propagate into command substitutions: a failing pipeline inside
# $(...) would otherwise fire rollback() once in the subshell (mutating real
# state) and again when the parent sees the failed cmdsub. With -E off, the trap
# fires once, in the main shell — which is what we want.
set +E

NM_STATE_FILE=/var/lib/NetworkManager/NetworkManager.state
DEFAULT_IP=10.0.0.200

# -----------------------------------------------------------------------------
# Argument parsing (defaults to 10.0.0.200)
# -----------------------------------------------------------------------------

print_usage() {
    cat <<EOF
usage: sudo bash $0 [<ipv4-address>]   (default: $DEFAULT_IP)

Pin this box to <ipv4-address> on its Ethernet interface and disable Wi-Fi
(reboot-persistent, reversible with 'sudo nmcli radio wifi on').

The script refuses to run unless the system is in the expected shape:
  - Ubuntu noble (24.04)
  - NetworkManager active; systemd-networkd inactive
  - Exactly one hardware Ethernet device with one active wired connection
  - Ethernet link UP with carrier; a default route runs through it
  - <ipv4-address> on the same /24 as the gateway, and not already in use
EOF
}

case "${1:-}" in
    -h|--help) print_usage; exit 0 ;;
esac

if [ "$#" -gt 1 ]; then
    print_usage >&2
    die "at most one positional argument (the target IPv4) is allowed"
fi
TARGET_IP="${1:-$DEFAULT_IP}"

# Root check fires here — before IPv4 syntactic validation — so that running
# without sudo reports the actual blocker ("must be run as root") rather than
# letting the user fix an IP-format error only to discover the sudo issue
# afterwards.
require_root

# -----------------------------------------------------------------------------
# Validate the target IPv4 address itself
# -----------------------------------------------------------------------------

if ! [[ "$TARGET_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    die "invalid IPv4 address: '$TARGET_IP' (not four dotted octets)"
fi
IFS='.' read -ra OCTETS <<< "$TARGET_IP"
for o in "${OCTETS[@]}"; do
    [ "$o" -ge 0 ] && [ "$o" -le 255 ] || die "invalid IPv4 octet '$o' in '$TARGET_IP' (out of range 0-255)"
done
[ "${OCTETS[0]}" -ne 0 ]   || die "invalid IPv4 '$TARGET_IP' (first octet 0 = network address)"
[ "${OCTETS[0]}" -ne 127 ] || die "invalid IPv4 '$TARGET_IP' (loopback range 127.0.0.0/8)"
[ "${OCTETS[3]}" -ne 0 ]   || die "invalid IPv4 '$TARGET_IP' (last octet 0 = network address)"
[ "${OCTETS[3]}" -ne 255 ] || die "invalid IPv4 '$TARGET_IP' (last octet 255 = broadcast)"

info "target IP: $TARGET_IP"

# -----------------------------------------------------------------------------
# Helpers (rollback, IP polling) and failure trap
# -----------------------------------------------------------------------------

# Set to 1 once the Ethernet profile has been switched to static; cleared once
# the static IP is verified end-to-end. The ERR trap rolls back only when 1.
ROLLBACK_NEEDED=0

# Captured during pre-flight; needed by rollback() to restore the original DHCP
# state on the Ethernet profile.
ETH_CON=""
ETH_DNS_ORIG=""
ETH_MAYFAIL_ORIG=""

rollback() {
    # Disarm ERR and relax -e: rollback proceeds best-effort and surfaces
    # failures of critical steps explicitly rather than silently exiting.
    trap - ERR
    set +e

    [ "$ROLLBACK_NEEDED" = "1" ] || return 0
    [ -n "$ETH_CON" ] || return 0

    warn "rolling back Ethernet to DHCP (original state)"

    # Restore the Ethernet profile to DHCP exactly as captured in pre-flight.
    # ipv4.dns is restored verbatim — including the empty case, where passing ""
    # clears the field, which is faithful. ipv4.may-fail is restored to whatever
    # the user originally had (we set it to 'no' during apply so IPv4 completion
    # gates the ACTIVATED transition — see the apply phase).
    nmcli connection modify "$ETH_CON" \
        ipv4.method auto \
        ipv4.addresses "" \
        ipv4.gateway "" \
        ipv4.dns "$ETH_DNS_ORIG" \
        ipv4.may-fail "$ETH_MAYFAIL_ORIG" 2>/dev/null

    # Cycle the profile so it drops the half-applied static and re-leases DHCP.
    # The `up` is checked explicitly: a silent failure would let us print
    # "rollback complete" while the system actually has no connectivity.
    local rollback_ok=1
    nmcli connection down "$ETH_CON" >/dev/null 2>&1
    sleep 1
    if ! nmcli connection up "$ETH_CON" >/dev/null 2>&1; then
        rollback_ok=0
        warn "  Ethernet ('$ETH_CON') did not come up — recover with: sudo nmcli connection up '$ETH_CON'"
    fi

    sleep 2
    if [ "$rollback_ok" = "1" ]; then
        warn "rollback complete — Ethernet restored to DHCP"
    else
        warn "ROLLBACK INCOMPLETE — see [warn] lines above for manual recovery"
    fi

    warn "post-rollback state:"
    ip -br -4 addr | grep -v -E '^(lo|docker|veth)'
    ip route show
}

abort() { rollback; exit 1; }

# Override common.sh's die() so a fatal error during the apply also rolls back.
die() { printf '[fatal] %s\n' "$*" >&2; abort; }

trap 'echo "[fatal] command failed at line $LINENO" >&2; abort' ERR

# Poll for an IPv4 on $1 within $2 seconds. Echoes the IP, returns 0/1. Skips
# link-local 169.254/16 — those mean DHCP failed and NM fell back to autoconf,
# which is NOT "got an IP" for our purposes.
wait_for_ipv4() {
    local iface="$1" timeout="${2:-20}" i out
    for i in $(seq 1 "$timeout"); do
        out=$(ip -4 -o addr show "$iface" 2>/dev/null \
              | awk '{print $4}' | cut -d/ -f1 \
              | grep -v '^169\.254\.' \
              | head -1) || out=""
        if [ -n "$out" ]; then
            printf '%s' "$out"
            return 0
        fi
        sleep 1
    done
    return 1
}

# Return the interface that holds exactly $1 as an IPv4 address. Echoes "" if
# zero, the only iface if exactly one, returns 2 if multiple hold it.
iface_holding_ip() {
    local target="$1" iface addr count=0 found=""
    while IFS= read -r line; do
        iface=$(printf '%s\n' "$line" | awk '{print $2}')
        addr=$(printf '%s\n' "$line"  | awk '{print $4}' | cut -d/ -f1)
        if [ "$addr" = "$target" ]; then
            count=$((count + 1))
            found="$iface"
        fi
    done < <(ip -4 -o addr show)
    if [ "$count" -gt 1 ]; then
        return 2
    fi
    printf '%s' "$found"
    return 0
}

# =============================================================================
# PHASE 1 — PRE-FLIGHT VALIDATION (no changes; can fail freely)
# =============================================================================

section "phase 1: pre-flight validation"

# 1.1 Required commands.
require_command nmcli
require_command ip
require_command ping
require_command awk
require_command grep
require_command cut
require_command systemctl

# 1.2 Distribution: Ubuntu noble (matches the rest of this repo).
require_ubuntu_noble

# 1.3 NetworkManager active.
require_systemd_active NetworkManager

# 1.4 No conflicting network manager.
if systemctl is-active --quiet systemd-networkd; then
    die "systemd-networkd is active alongside NetworkManager — this script requires NetworkManager to be the sole network manager"
fi

# 1.5 Exactly one HARDWARE Ethernet device (exclude veth pairs and other virtual
#     802-3-ethernet entries; real NICs back onto a /sys/class/net/<iface>/device).
mapfile -t ETH_DEVS_ALL < <(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2 == "ethernet" {print $1}')
ETH_DEVS_HW=()
for d in "${ETH_DEVS_ALL[@]:-}"; do
    [ -n "$d" ] && [ -e "/sys/class/net/$d/device" ] && ETH_DEVS_HW+=("$d")
done
[ "${#ETH_DEVS_HW[@]}" -eq 1 ] \
    || die "expected exactly one hardware Ethernet device, found ${#ETH_DEVS_HW[@]}: ${ETH_DEVS_HW[*]:-<none>}"
ETH_IFACE="${ETH_DEVS_HW[0]}"

# 1.6 Exactly one active wired connection (802-3-ethernet specifically — excludes
#     bridges, vpn, tun, etc.).
mapfile -t ETH_ACTIVE < <(nmcli -t -f NAME,TYPE,STATE connection show --active \
    | awk -F: '$2 == "802-3-ethernet" && $3 == "activated" {print $1}')
[ "${#ETH_ACTIVE[@]}" -eq 1 ] \
    || die "expected exactly one active wired connection, found ${#ETH_ACTIVE[@]}: ${ETH_ACTIVE[*]:-<none>}"
ETH_CON="${ETH_ACTIVE[0]}"

# 1.7 The active wired connection must be bound to the expected hardware device.
ETH_CON_DEV=$(nmcli -t -f GENERAL.DEVICES connection show "$ETH_CON" | head -1 | cut -d: -f2-)
[ "$ETH_CON_DEV" = "$ETH_IFACE" ] \
    || die "wired connection '$ETH_CON' is on '$ETH_CON_DEV', not the Ethernet device '$ETH_IFACE'"

# 1.8 Carrier on the Ethernet interface (cable plugged in).
[ "$(cat "/sys/class/net/$ETH_IFACE/carrier" 2>/dev/null)" = "1" ] \
    || die "$ETH_IFACE has no carrier — is the Ethernet cable plugged in?"

# 1.9 Gateway: take it from the live default route on the Ethernet interface.
#     (Ethernet is the NIC we are pinning; its own default-route gateway is the
#     authoritative next hop for the segment it lives on.)
GATEWAY=$(ip -4 route show default dev "$ETH_IFACE" 2>/dev/null | awk '/^default/ {print $3; exit}')
[ -n "$GATEWAY" ] \
    || die "no default route via $ETH_IFACE — cannot determine the gateway to use"

# 1.10 Gateway and target IP on the same /24.
gw_prefix=$(    echo "$GATEWAY"   | awk -F. '{print $1"."$2"."$3}')
target_prefix=$(echo "$TARGET_IP" | awk -F. '{print $1"."$2"."$3}')
[ "$gw_prefix" = "$target_prefix" ] \
    || die "gateway $GATEWAY not on same /24 as target $TARGET_IP"

# 1.11 Baseline connectivity: the gateway responds right now.
ping -c 1 -W 2 "$GATEWAY" >/dev/null 2>&1 \
    || die "gateway $GATEWAY does not respond to ping right now (baseline broken)"

# 1.12 Read the current Ethernet profile, and capture the fields rollback must
#      restore byte-for-byte. ipv4.may-fail is a tristate-as-string in nmcli
#      output ("yes"/"no"); a missing value means we're talking to an nmcli we
#      don't understand, so we refuse rather than guess what to restore.
ETH_METHOD=$(  nmcli -t -f ipv4.method     connection show "$ETH_CON" | cut -d: -f2-)
ETH_ADDR=$(    nmcli -t -f ipv4.addresses  connection show "$ETH_CON" | cut -d: -f2-)
ETH_DNS_ORIG=$(nmcli -t -f ipv4.dns        connection show "$ETH_CON" | cut -d: -f2-)
ETH_MAYFAIL_ORIG=$(nmcli -t -f ipv4.may-fail connection show "$ETH_CON" | cut -d: -f2-)
[ -n "$ETH_MAYFAIL_ORIG" ] \
    || die "could not read ipv4.may-fail from Ethernet profile '$ETH_CON' — refusing to proceed without a value to restore on rollback"

# 1.13 Decide whether the static IP is already in place (idempotent re-run) or
#      needs to be applied. Everything outside these cases is refused:
#        - method=manual, addresses=<target>/24  -> already done, skip apply
#        - method=manual, addresses=<other>      -> refuse (don't clobber)
#        - method=auto (DHCP)                     -> fresh, will apply
STATIC_ALREADY=0
if [ "$ETH_METHOD" = "manual" ]; then
    if [ "$ETH_ADDR" = "$TARGET_IP/24" ]; then
        STATIC_ALREADY=1
    else
        die "Ethernet profile '$ETH_CON' already has a different static address '$ETH_ADDR' (expected '$TARGET_IP/24') — refusing to overwrite"
    fi
elif [ "$ETH_METHOD" != "auto" ]; then
    die "Ethernet profile '$ETH_CON' has ipv4.method='$ETH_METHOD', expected 'auto' (DHCP) or an existing '$TARGET_IP/24' static"
fi

# 1.14 When applying fresh, the target IP must not already be in use. Skipped on
#      an idempotent re-run, where the target is our own address (the post-apply
#      checks in phase 3 still prove it ends up only on Ethernet).
if [ "$STATIC_ALREADY" = "0" ]; then
    HOLDER=$(iface_holding_ip "$TARGET_IP") \
        || die "target IP $TARGET_IP is held by multiple local interfaces — refuse to proceed"
    if [ -z "$HOLDER" ]; then
        # Nobody local holds it — make sure no other LAN host does either.
        if ping -c 1 -W 1 "$TARGET_IP" >/dev/null 2>&1; then
            die "$TARGET_IP responds to ping — another device on the LAN is already using it"
        fi
        info "$TARGET_IP is unused — proceeding"
    elif [ "$HOLDER" = "$ETH_IFACE" ]; then
        # DHCP already handed Ethernet exactly the target; pinning it static to
        # the same address is safe and is the intended end state.
        info "$TARGET_IP already on $ETH_IFACE via DHCP — will pin it static"
    else
        die "$TARGET_IP is currently held by '$HOLDER', not $ETH_IFACE — refuse to move it implicitly"
    fi
fi

# 1.15 Detect the Wi-Fi device, if any. At most one is expected; the radio is
#      disabled in phase 4. Zero is fine — an Ethernet-only box has none.
mapfile -t WIFI_DEVS < <(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2 == "wifi" {print $1}')
[ "${#WIFI_DEVS[@]}" -le 1 ] \
    || die "expected at most one Wi-Fi device, found ${#WIFI_DEVS[@]}: ${WIFI_DEVS[*]}"
WIFI_IFACE="${WIFI_DEVS[0]:-}"

info "pre-flight: PASS"
info "  Ethernet: '$ETH_CON' on $ETH_IFACE — ipv4.method=$ETH_METHOD"
info "  Gateway:  $GATEWAY (reachable)"
info "  Wi-Fi:    ${WIFI_IFACE:-<none present>}"

# =============================================================================
# PHASE 2 — APPLY STATIC IP ON ETHERNET (rollback-protected)
# =============================================================================

if [ "$STATIC_ALREADY" = "1" ]; then
    section "phase 2: static IP already in place — skipping apply"
    info "Ethernet profile '$ETH_CON' is already manual at $TARGET_IP/24"
else
    section "phase 2: switch Ethernet to static $TARGET_IP/24 via $GATEWAY"

    ROLLBACK_NEEDED=1

    # ipv4.may-fail=no on the Ethernet profile is load-bearing. By default
    # may-fail=yes, so NetworkManager flips the device to ACTIVATED as soon as
    # EITHER address family finishes its IP method — not both. So `nmcli
    # connection up` can return while the IPv4 static address and default route
    # are not yet in the kernel (the v6 method won the dual-stack race), and the
    # phase-3 route assertion would then read whatever other default route
    # exists and spuriously fail. Setting may-fail=no forces ACTIVATED to wait
    # for IPv4 specifically, which closes that window.
    nmcli connection modify "$ETH_CON" \
        ipv4.method   manual \
        ipv4.addresses "$TARGET_IP/24" \
        ipv4.gateway  "$GATEWAY" \
        ipv4.dns      "$GATEWAY 8.8.8.8" \
        ipv4.may-fail no
    info "Ethernet profile staged: manual $TARGET_IP/24 gw=$GATEWAY may-fail=no"

    nmcli connection down "$ETH_CON" >/dev/null 2>&1 || true
    sleep 2
    # -w 60: with may-fail=no, `connection up` blocks until the IPv4 method has
    # fully completed (static address AND default route installed in the kernel),
    # not just until v6 wins. 60s is comfortably above the fraction of a second
    # a static bring-up actually needs.
    nmcli -w 60 connection up "$ETH_CON" >/dev/null 2>&1 \
        || die "'nmcli -w 60 connection up $ETH_CON' failed"

    NEW_ETH_IP=$(wait_for_ipv4 "$ETH_IFACE" 15) \
        || die "Ethernet did not get an IPv4 within 15s after cycling"
    [ "$NEW_ETH_IP" = "$TARGET_IP" ] \
        || die "Ethernet came up at $NEW_ETH_IP, expected $TARGET_IP"
    info "Ethernet now on $NEW_ETH_IP (static)"
fi

# =============================================================================
# PHASE 3 — VALIDATE STATIC IP END-TO-END ON ETHERNET
# =============================================================================
# Prove the static address actually works on Ethernet before we touch Wi-Fi.

section "phase 3: validate connectivity on $ETH_IFACE"

# 3.1 Target IP held by exactly the Ethernet interface.
CURR_TARGET_IFACE=""
if ! CURR_TARGET_IFACE=$(iface_holding_ip "$TARGET_IP"); then
    die "$TARGET_IP held by multiple interfaces — refuse"
fi
[ "$CURR_TARGET_IFACE" = "$ETH_IFACE" ] \
    || die "$TARGET_IP held by '${CURR_TARGET_IFACE:-<none>}', expected '$ETH_IFACE'"
info "$TARGET_IP confirmed only on $ETH_IFACE"

# 3.2 Kernel routes outbound (1.1.1.1) via Ethernet. Polled, not one-shot:
#     nm-policy updates which active connection owns the default route AFTER the
#     device reaches ACTIVATED, and kernel-FIB visibility of NM-installed routes
#     is itself eventually-consistent in places. 10s is empirically generous —
#     the first iteration normally already passes.
ROUTE_DEV=""
for _ in $(seq 1 10); do
    ROUTE_DEV=$(ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    [ "$ROUTE_DEV" = "$ETH_IFACE" ] && break
    sleep 1
done
[ "$ROUTE_DEV" = "$ETH_IFACE" ] \
    || die "kernel routes 1.1.1.1 via '${ROUTE_DEV:-<none>}', expected '$ETH_IFACE' (waited 10s)"
info "kernel routes 1.1.1.1 via $ETH_IFACE"

# 3.3 Gateway reachable specifically via Ethernet.
ping -c 2 -W 3 -I "$ETH_IFACE" "$GATEWAY" >/dev/null 2>&1 \
    || die "gateway $GATEWAY not reachable bound to $ETH_IFACE"
info "gateway $GATEWAY reachable via $ETH_IFACE"

# 3.4 Internet reachable specifically via Ethernet.
ping -c 2 -W 3 -I "$ETH_IFACE" 1.1.1.1 >/dev/null 2>&1 \
    || ping -c 2 -W 3 -I "$ETH_IFACE" 8.8.8.8 >/dev/null 2>&1 \
    || die "internet not reachable bound to $ETH_IFACE"
info "internet reachable via $ETH_IFACE"

# Static IP verified end-to-end. Disarm rollback. From here on, do not fail.
ROLLBACK_NEEDED=0
trap - ERR
info "static IP verified end-to-end — committing"

# =============================================================================
# PHASE 4 — DISABLE WI-FI (committed; warn-only on anomalies)
# =============================================================================
# The critical path (static IP on Ethernet) has succeeded. Disabling the radio
# is best-effort and reversible at any time with `sudo nmcli radio wifi on`, so
# anomalies here are warnings, never a non-zero exit.

section "phase 4: disable Wi-Fi (reboot-persistent, reversible)"

if [ -z "$WIFI_IFACE" ]; then
    info "no Wi-Fi device present — nothing to disable"
else
    if ! nmcli radio wifi off; then
        warn "'nmcli radio wifi off' returned non-zero — retry manually if Wi-Fi is still on"
    fi

    WIFI_RADIO_STATE=$(nmcli radio wifi 2>/dev/null || echo "<unknown>")
    if [ "$WIFI_RADIO_STATE" = "disabled" ]; then
        info "nmcli radio wifi: disabled"
    else
        warn "nmcli radio wifi reports '$WIFI_RADIO_STATE' (expected 'disabled')"
    fi

    sleep 2
    WIFI_RESID_IP=$(ip -4 -o addr show "$WIFI_IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1) || WIFI_RESID_IP=""
    if [ -z "$WIFI_RESID_IP" ]; then
        info "$WIFI_IFACE has no IPv4 — Wi-Fi confirmed down"
    else
        warn "$WIFI_IFACE still holds $WIFI_RESID_IP after radio off (anomalous)"
    fi

    # Persistence: NetworkManager records the radio state here; 'false' survives
    # reboots.
    if [ -f "$NM_STATE_FILE" ] && grep -q '^WirelessEnabled=false' "$NM_STATE_FILE"; then
        info "persistence verified: 'WirelessEnabled=false' in $NM_STATE_FILE — survives reboot"
    else
        warn "could not confirm 'WirelessEnabled=false' in $NM_STATE_FILE — Wi-Fi may re-enable on reboot; verify manually"
    fi
fi

# Final internet check, independent of which NIC carries it.
if ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 || ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
    info "internet reachable"
else
    warn "internet check failed at end of run — the Ethernet route should work; investigate"
fi

# =============================================================================
# FINAL REPORT
# =============================================================================

section "DONE"
echo "Addresses (excluding lo/docker/veth):"
ip -br -4 addr | grep -v -E '^(lo|docker|veth)' || true
echo
echo "Routing table:"
ip route show
echo
echo "NM connections:"
nmcli -t -f NAME,TYPE,STATE,DEVICE connection show
echo
echo "Radio state:"
nmcli radio
echo
info "static IP $TARGET_IP is live on $ETH_IFACE via gateway $GATEWAY."
info "now update the router's DMZ target on the router admin UI to: $TARGET_IP"
if [ -n "$WIFI_IFACE" ]; then
    echo "To re-enable Wi-Fi later:  sudo nmcli radio wifi on"
fi

exit 0
