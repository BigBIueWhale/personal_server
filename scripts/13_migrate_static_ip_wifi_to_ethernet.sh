#!/usr/bin/env bash
# scripts/13_migrate_static_ip_wifi_to_ethernet.sh — move the static IPv4 from
# Wi-Fi to Ethernet, then disable Wi-Fi (reboot-persistent, reversible).
#
# Designed for the very specific case this project lives in:
#   - Single host with one Wi-Fi card and one Ethernet NIC, both on the same /24.
#   - Wi-Fi currently holds a static IPv4 (set earlier by 01_set_static_ip.sh).
#   - Ethernet currently runs DHCP from the same router.
#   - Owner now wants the box to live on Ethernet at the same static IP, with
#     Wi-Fi disabled but recoverable on demand.
#
# What this does (in order):
#   1. Exhaustive pre-flight validation — refuses to run unless the system is
#      *exactly* in the expected state. No auto-repair, no guessing across
#      multiple candidates.
#   2. Stages NetworkManager profile changes (no live effect yet):
#        - Wi-Fi profile: ipv4.method=auto (DHCP), addresses/gateway/dns cleared
#        - Eth   profile: ipv4.method=manual, addresses=<target>/24,
#                         gateway=<auto-detected from current Wi-Fi profile>,
#                         dns=<gateway> 8.8.8.8
#   3. Cycles Wi-Fi (releases the static IP, gets a DHCP lease on something else).
#      Internet stays up via Ethernet's existing DHCP route during this window.
#   4. Cycles Ethernet (claims the static IP).
#      Internet stays up via Wi-Fi's new DHCP route during this window.
#   5. Validates end-to-end on the new NIC: target IP exclusively on Ethernet,
#      kernel routes outbound via Ethernet, gateway pings via Ethernet, internet
#      pings via Ethernet.
#   6. Disables the Wi-Fi radio (`nmcli radio wifi off`).
#      Persists across reboots via /var/lib/NetworkManager/NetworkManager.state.
#      Reversible at any time with: sudo nmcli radio wifi on
#
# Failure semantics:
#   - Anything in steps 1–5 fails -> automatic rollback to the original state
#     (Wi-Fi static <target>/24, Ethernet DHCP). Script exits non-zero.
#   - Once step 5 has passed, the swap is *committed*. Step 6 is best-effort:
#     anomalies are reported as warnings; the script does not exit non-zero
#     after commit, on the principle that the user is now in a working state
#     and a partial failure of the radio toggle should not look like a swap
#     failure.
#
# Usage:
#   sudo bash scripts/13_migrate_static_ip_wifi_to_ethernet.sh <target-ipv4>
#
# Examples:
#   sudo bash scripts/13_migrate_static_ip_wifi_to_ethernet.sh 10.0.0.199
#
# After this script succeeds the router's DMZ rule (which targets the static IP)
# does not need to change — the IP is the same, only the NIC carrying it has
# changed. Stale ARP caches on the LAN may take ~30s to refresh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

# common.sh enables `set -Eeuo pipefail`. We disable -E here so the ERR trap
# below does NOT propagate into command substitutions: a failing pipeline
# inside $(...) would otherwise fire rollback() once in the subshell (mutating
# real state) and again when the parent sees the failed cmdsub. With -E off,
# the trap fires once, in the main shell — which is what we want.
set +E

NM_STATE_FILE=/var/lib/NetworkManager/NetworkManager.state

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

print_usage() {
    cat <<EOF
usage: sudo bash $0 <target-ipv4>

Move <target-ipv4> from the active Wi-Fi connection to the active Ethernet
connection, then disable Wi-Fi (reboot-persistent, reversible with
'sudo nmcli radio wifi on').

The script refuses to run unless the system is in EXACTLY this state:
  - Ubuntu noble (24.04)
  - NetworkManager active; systemd-networkd inactive
  - Exactly one Wi-Fi device, exactly one hardware Ethernet device
  - Exactly one active wireless connection, exactly one active wired connection
  - Wi-Fi connection: ipv4.method=manual with ipv4.addresses=<target-ipv4>/24
  - Ethernet connection: ipv4.method=auto with a current DHCP lease
  - <target-ipv4> currently held only by the Wi-Fi interface
  - Default route via the Wi-Fi profile's gateway exists and is reachable
EOF
}

case "${1:-}" in
    -h|--help) print_usage; exit 0 ;;
esac

[ "$#" -eq 1 ] || { print_usage >&2; die "exactly one positional argument required"; }
TARGET_IP="$1"

# Root check fires here — before IPv4 syntactic validation — so that running
# without sudo reports the actual blocker ("must be run as root") rather than
# letting the user fix an IP-format error only to discover the sudo issue
# afterwards. Matches the order used in 01_set_static_ip.sh.
require_root

# -----------------------------------------------------------------------------
# Validate the target IPv4 syntactically
# -----------------------------------------------------------------------------

if ! [[ "$TARGET_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    die "invalid IPv4: '$TARGET_IP' (not four dotted octets)"
fi
IFS='.' read -ra OCTETS <<< "$TARGET_IP"
for o in "${OCTETS[@]}"; do
    [ "$o" -ge 0 ] && [ "$o" -le 255 ] || die "invalid octet '$o' in '$TARGET_IP'"
done
[ "${OCTETS[0]}" -ne 0   ] || die "invalid IPv4 '$TARGET_IP' (first octet 0 = network)"
[ "${OCTETS[0]}" -ne 127 ] || die "invalid IPv4 '$TARGET_IP' (loopback range)"
[ "${OCTETS[3]}" -ne 0   ] || die "invalid IPv4 '$TARGET_IP' (last octet 0 = network)"
[ "${OCTETS[3]}" -ne 255 ] || die "invalid IPv4 '$TARGET_IP' (last octet 255 = broadcast)"

# -----------------------------------------------------------------------------
# Helpers (rollback, IP polling)
# -----------------------------------------------------------------------------

# Set to 1 once profile changes have been staged; cleared once the swap is
# verified end-to-end. The ERR trap rolls back only when this is 1.
ROLLBACK_NEEDED=0

# Captured during pre-flight; needed by rollback() to restore original state.
WIFI_CON=""
ETH_CON=""
WIFI_DNS_ORIG=""
ETH_MAYFAIL_ORIG=""

rollback() {
    # Disarm ERR and relax -e: rollback proceeds best-effort and surfaces
    # failures of critical steps explicitly rather than silently exiting.
    trap - ERR
    set +e

    [ "$ROLLBACK_NEEDED" = "1" ] || return 0
    [ -n "$WIFI_CON" ] && [ -n "$ETH_CON" ] || return 0

    warn "rolling back to original state (Wi-Fi static $TARGET_IP, Ethernet DHCP)"

    # Restore both profiles verbatim from values captured in pre-flight.
    # WIFI_DNS_ORIG holds the user's original DNS exactly — including the
    # empty case (passing "" to ipv4.dns clears the field, which is faithful).
    # ETH_MAYFAIL_ORIG restores ipv4.may-fail (we set it to 'no' in phase 2 so
    # IPv4 method completion gates the ACTIVATED transition; rollback should
    # leave the DHCP profile with whatever the user originally had).
    nmcli connection modify "$ETH_CON" \
        ipv4.method auto \
        ipv4.addresses "" \
        ipv4.gateway "" \
        ipv4.dns "" \
        ipv4.may-fail "$ETH_MAYFAIL_ORIG" 2>/dev/null

    nmcli connection modify "$WIFI_CON" \
        ipv4.method manual \
        ipv4.addresses "$TARGET_IP/24" \
        ipv4.gateway "$GATEWAY" \
        ipv4.dns "$WIFI_DNS_ORIG" 2>/dev/null

    # Cycle Ethernet first so it drops any half-applied static; then cycle
    # Wi-Fi so it re-claims the static IP. Never both holding the IP at once.
    # Each `up` is checked explicitly: a silent failure would let us print
    # "rollback complete" while the system actually has no connectivity.
    local rollback_ok=1

    nmcli connection down "$ETH_CON" >/dev/null 2>&1
    sleep 1
    if ! nmcli connection up "$ETH_CON" >/dev/null 2>&1; then
        rollback_ok=0
        warn "  Ethernet ('$ETH_CON') did not come up — recover with: sudo nmcli connection up '$ETH_CON'"
    fi

    nmcli connection down "$WIFI_CON" >/dev/null 2>&1
    sleep 1
    if ! nmcli connection up "$WIFI_CON" >/dev/null 2>&1; then
        rollback_ok=0
        warn "  Wi-Fi ('$WIFI_CON') did not come up — recover with: sudo nmcli connection up '$WIFI_CON'"
    fi

    sleep 2
    if [ "$rollback_ok" = "1" ]; then
        warn "rollback complete — system restored to original state"
    else
        warn "ROLLBACK INCOMPLETE — see [warn] lines above for manual recovery"
    fi

    warn "post-rollback state:"
    ip -br -4 addr | grep -v -E '^(lo|docker|veth)'
    ip route show
}

abort() { rollback; exit 1; }

# Override common.sh's die() so a fatal error during the swap also rolls back.
die() { printf '[fatal] %s\n' "$*" >&2; abort; }

trap 'echo "[fatal] command failed at line $LINENO" >&2; abort' ERR

# Poll for an IPv4 on $1 within $2 seconds. Echoes the IP, returns 0/1.
# Skips link-local 169.254/16 — those mean DHCP failed and NM fell back to
# autoconf, which is NOT "got an IP" for our purposes.
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

# Return interface that holds exactly $1 as an IPv4 address. Echoes "" if zero,
# echoes the only iface if exactly one, fails (returns 2) if multiple.
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

# 1.1 Required commands. (Root was already enforced earlier, before any
#     argument validation, so we don't repeat the check here.)
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

# 1.5 Exactly one Wi-Fi device (filter type=wifi to exclude wifi-p2p siblings).
mapfile -t WIFI_DEVS < <(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2 == "wifi" {print $1}')
[ "${#WIFI_DEVS[@]}" -eq 1 ] \
    || die "expected exactly one Wi-Fi device, found ${#WIFI_DEVS[@]}: ${WIFI_DEVS[*]:-<none>}"
WIFI_IFACE="${WIFI_DEVS[0]}"

# 1.6 Exactly one HARDWARE Ethernet device (exclude veth pairs and other virtual
#     802-3-ethernet entries; real NICs back onto a /sys/class/net/<iface>/device).
mapfile -t ETH_DEVS_ALL < <(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2 == "ethernet" {print $1}')
ETH_DEVS_HW=()
for d in "${ETH_DEVS_ALL[@]:-}"; do
    [ -n "$d" ] && [ -e "/sys/class/net/$d/device" ] && ETH_DEVS_HW+=("$d")
done
[ "${#ETH_DEVS_HW[@]}" -eq 1 ] \
    || die "expected exactly one hardware Ethernet device, found ${#ETH_DEVS_HW[@]}: ${ETH_DEVS_HW[*]:-<none>}"
ETH_IFACE="${ETH_DEVS_HW[0]}"

# 1.7 Exactly one active wireless connection.
mapfile -t WIFI_ACTIVE < <(nmcli -t -f NAME,TYPE,STATE connection show --active \
    | awk -F: '$2 == "802-11-wireless" && $3 == "activated" {print $1}')
[ "${#WIFI_ACTIVE[@]}" -eq 1 ] \
    || die "expected exactly one active wireless connection, found ${#WIFI_ACTIVE[@]}: ${WIFI_ACTIVE[*]:-<none>}"
WIFI_CON="${WIFI_ACTIVE[0]}"

# 1.8 Exactly one active wired connection (802-3-ethernet specifically — excludes
#     bridges, vpn, tun, etc.).
mapfile -t ETH_ACTIVE < <(nmcli -t -f NAME,TYPE,STATE connection show --active \
    | awk -F: '$2 == "802-3-ethernet" && $3 == "activated" {print $1}')
[ "${#ETH_ACTIVE[@]}" -eq 1 ] \
    || die "expected exactly one active wired connection, found ${#ETH_ACTIVE[@]}: ${ETH_ACTIVE[*]:-<none>}"
ETH_CON="${ETH_ACTIVE[0]}"

# 1.9 Active connections must be bound to the expected hardware devices.
WIFI_CON_DEV=$(nmcli -t -f GENERAL.DEVICES connection show "$WIFI_CON" | head -1 | cut -d: -f2-)
ETH_CON_DEV=$( nmcli -t -f GENERAL.DEVICES connection show "$ETH_CON"  | head -1 | cut -d: -f2-)
[ "$WIFI_CON_DEV" = "$WIFI_IFACE" ] \
    || die "wireless connection '$WIFI_CON' is on '$WIFI_CON_DEV', not the Wi-Fi device '$WIFI_IFACE'"
[ "$ETH_CON_DEV" = "$ETH_IFACE" ] \
    || die "wired connection '$ETH_CON' is on '$ETH_CON_DEV', not the Ethernet device '$ETH_IFACE'"

# 1.10 Carrier on both interfaces.
[ "$(cat "/sys/class/net/$WIFI_IFACE/carrier" 2>/dev/null)" = "1" ] \
    || die "$WIFI_IFACE has no carrier (Wi-Fi not associated with an AP)"
[ "$(cat "/sys/class/net/$ETH_IFACE/carrier"  2>/dev/null)" = "1" ] \
    || die "$ETH_IFACE has no carrier — is the Ethernet cable plugged in?"

# 1.11 Wi-Fi profile is exactly the expected static config.
WIFI_METHOD=$(nmcli -t -f ipv4.method    connection show "$WIFI_CON" | cut -d: -f2-)
WIFI_ADDR=$(  nmcli -t -f ipv4.addresses connection show "$WIFI_CON" | cut -d: -f2-)
WIFI_GW=$(    nmcli -t -f ipv4.gateway   connection show "$WIFI_CON" | cut -d: -f2-)
WIFI_DNS_ORIG=$(nmcli -t -f ipv4.dns     connection show "$WIFI_CON" | cut -d: -f2-)
[ "$WIFI_METHOD" = "manual" ] \
    || die "Wi-Fi profile '$WIFI_CON' has ipv4.method='$WIFI_METHOD', expected 'manual' (this script only swaps an existing static config)"
[ "$WIFI_ADDR" = "$TARGET_IP/24" ] \
    || die "Wi-Fi profile '$WIFI_CON' has ipv4.addresses='$WIFI_ADDR', expected '$TARGET_IP/24'"
[ -n "$WIFI_GW" ] \
    || die "Wi-Fi profile '$WIFI_CON' has no ipv4.gateway set"

GATEWAY="$WIFI_GW"

# 1.12 Gateway and target IP on same /24.
gw_prefix=$(    echo "$GATEWAY"   | awk -F. '{print $1"."$2"."$3}')
target_prefix=$(echo "$TARGET_IP" | awk -F. '{print $1"."$2"."$3}')
[ "$gw_prefix" = "$target_prefix" ] \
    || die "gateway $GATEWAY not on same /24 as target $TARGET_IP"

# 1.13 Ethernet profile is exactly DHCP (no leftover static fields). Also
#      capture ipv4.may-fail so rollback can restore it byte-for-byte (we
#      override it to 'no' in phase 2 — see comment there).
ETH_METHOD=$(  nmcli -t -f ipv4.method    connection show "$ETH_CON" | cut -d: -f2-)
ETH_ADDR=$(    nmcli -t -f ipv4.addresses connection show "$ETH_CON" | cut -d: -f2-)
ETH_GW=$(      nmcli -t -f ipv4.gateway   connection show "$ETH_CON" | cut -d: -f2-)
ETH_MAYFAIL_ORIG=$(nmcli -t -f ipv4.may-fail connection show "$ETH_CON" | cut -d: -f2-)
[ "$ETH_METHOD" = "auto" ] \
    || die "Ethernet profile '$ETH_CON' has ipv4.method='$ETH_METHOD', expected 'auto' (DHCP)"
[ -z "$ETH_ADDR" ] \
    || die "Ethernet profile '$ETH_CON' has stray ipv4.addresses='$ETH_ADDR' (expected empty for DHCP profile)"
[ -z "$ETH_GW" ] \
    || die "Ethernet profile '$ETH_CON' has stray ipv4.gateway='$ETH_GW' (expected empty for DHCP profile)"
# ipv4.may-fail is a tristate-as-string in nmcli output ("yes" or "no"); a
# missing value would mean we're talking to an nmcli we don't understand.
[ -n "$ETH_MAYFAIL_ORIG" ] \
    || die "could not read ipv4.may-fail from Ethernet profile '$ETH_CON' — refusing to proceed without a value to restore on rollback"

# 1.14 Ethernet currently has a DHCP-assigned IPv4.
ETH_CURR_IP=$(ip -4 -o addr show "$ETH_IFACE" | awk '{print $4}' | cut -d/ -f1 | head -1)
[ -n "$ETH_CURR_IP" ] \
    || die "$ETH_IFACE has no IPv4 — DHCP not currently working"

# 1.15 The target IP is currently held only by the Wi-Fi interface.
CURR_TARGET_IFACE=""
if ! CURR_TARGET_IFACE=$(iface_holding_ip "$TARGET_IP"); then
    die "target IP $TARGET_IP is held by multiple interfaces simultaneously — refuse to proceed"
fi
[ "$CURR_TARGET_IFACE" = "$WIFI_IFACE" ] \
    || die "target IP $TARGET_IP is currently on '${CURR_TARGET_IFACE:-<no interface>}', expected '$WIFI_IFACE'"

# 1.16 Default route via the gateway exists. (-F so dots in $GATEWAY aren't
#      interpreted as regex any-char; the trailing space is always present in
#      `ip route` output between the gateway IP and the next field.)
ip route show default | grep -qF "via $GATEWAY " \
    || die "no default route via $GATEWAY in current routing table"

# 1.17 Baseline connectivity: gateway pings, internet reaches.
ping -c 1 -W 2 "$GATEWAY" >/dev/null 2>&1 \
    || die "gateway $GATEWAY does not respond to ping right now (baseline broken)"
ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 \
    || ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 \
    || die "no outbound internet right now (baseline broken; tried 1.1.1.1 and 8.8.8.8)"

# 1.18 NM state file present and currently shows wifi-enabled (so we have
#      something to flip and a way to verify persistence afterward).
[ -f "$NM_STATE_FILE" ] \
    || die "$NM_STATE_FILE missing — cannot verify wifi-disable persistence"
[ -r "$NM_STATE_FILE" ] \
    || die "$NM_STATE_FILE not readable as root — unexpected"
grep -q '^WirelessEnabled=true' "$NM_STATE_FILE" \
    || die "expected 'WirelessEnabled=true' currently in $NM_STATE_FILE — wifi state ambiguous"

info "pre-flight: PASS"
info "  Wi-Fi:    '$WIFI_CON' on $WIFI_IFACE — manual $WIFI_ADDR gw=$WIFI_GW"
info "  Ethernet: '$ETH_CON' on $ETH_IFACE — auto, currently $ETH_CURR_IP"
info "  Gateway:  $GATEWAY (reachable, internet OK)"

# =============================================================================
# PHASE 2 — STAGE PROFILE CHANGES (no live effect; rollback-protected)
# =============================================================================

section "phase 2: stage profile changes"

ROLLBACK_NEEDED=1

nmcli connection modify "$WIFI_CON" \
    ipv4.method auto \
    ipv4.addresses "" \
    ipv4.gateway "" \
    ipv4.dns ""
info "Wi-Fi profile staged: ipv4.method=auto"

# ipv4.may-fail=no on the Ethernet profile is load-bearing.
#
# By default ipv4.may-fail=yes, which means NetworkManager flips the device to
# the ACTIVATED state as soon as EITHER address family (v4 or v6) finishes its
# IP method — not when both do. So `nmcli connection up` can return success
# while the IPv4 default route has not yet been installed in the kernel: the
# v6 method finished first, ACTIVATED was signalled, nmcli returned, and v4
# (including the static default route via $GATEWAY) is still being applied
# asynchronously. With v4 not yet in the FIB, `ip route get 1.1.1.1` falls
# through to whatever other default route exists — in our case the cycled
# Wi-Fi profile's freshly-acquired DHCP route on metric 600 — and the post-
# swap route assertion in phase 5 incorrectly fires. Setting may-fail=no
# forces ACTIVATED to wait for v4 specifically, which closes that window.
#
# (See NetworkManager-wait-online(8): "by default, NetworkManager considers
# the device as fully activated already when only one of the address families
# is ready." Phase 5 still polls the kernel FIB defensively because the
# `Default` D-Bus property — i.e. which Active Connection currently OWNS the
# default route — is updated by nm-policy *after* ACTIVATED.)
nmcli connection modify "$ETH_CON" \
    ipv4.method   manual \
    ipv4.addresses "$TARGET_IP/24" \
    ipv4.gateway  "$GATEWAY" \
    ipv4.dns      "$GATEWAY 8.8.8.8" \
    ipv4.may-fail no
info "Ethernet profile staged: ipv4.method=manual $TARGET_IP/24 gw=$GATEWAY may-fail=no"

# =============================================================================
# PHASE 3 — APPLY: cycle Wi-Fi (releases target IP, gets DHCP)
# =============================================================================
# Ethernet still on DHCP at $ETH_CURR_IP — internet stays up via Ethernet.

section "phase 3: cycle Wi-Fi (releases $TARGET_IP, gets DHCP)"

nmcli connection down "$WIFI_CON" >/dev/null 2>&1 || true
sleep 2
# -w 60: explicit timeout. nmcli's documented default for `connection up` is
# 90s on this version; we cap a bit shorter so a stuck Wi-Fi bring-up doesn't
# leave the user staring at a silent shell, while still giving DHCP plenty of
# time to lease.
nmcli -w 60 connection up "$WIFI_CON" >/dev/null 2>&1 \
    || die "'nmcli -w 60 connection up $WIFI_CON' failed"

NEW_WIFI_IP=$(wait_for_ipv4 "$WIFI_IFACE" 20) \
    || die "Wi-Fi did not get an IPv4 within 20s after cycling — DHCP issue?"
[ "$NEW_WIFI_IP" != "$TARGET_IP" ] \
    || die "Wi-Fi DHCP returned $TARGET_IP — refusing to proceed (DHCP server thinks $TARGET_IP is in its pool?)"
info "Wi-Fi now on $NEW_WIFI_IP (DHCP)"

# =============================================================================
# PHASE 4 — APPLY: cycle Ethernet (claims target IP static)
# =============================================================================
# Wi-Fi now on DHCP at $NEW_WIFI_IP; internet stays up via Wi-Fi during the
# brief Ethernet-down window.

section "phase 4: cycle Ethernet (claims static $TARGET_IP)"

nmcli connection down "$ETH_CON" >/dev/null 2>&1 || true
sleep 2
# -w 60: with ipv4.may-fail=no on this profile (set in phase 2), `nmcli
# connection up` blocks until the IPv4 method has fully completed — i.e.
# until the static address AND default route are installed in the kernel,
# not just until v6 wins the dual-stack race. 60s is comfortably above the
# fraction of a second a static-method bring-up actually needs.
nmcli -w 60 connection up "$ETH_CON" >/dev/null 2>&1 \
    || die "'nmcli -w 60 connection up $ETH_CON' failed"

NEW_ETH_IP=$(wait_for_ipv4 "$ETH_IFACE" 15) \
    || die "Ethernet did not get an IPv4 within 15s after cycling"
[ "$NEW_ETH_IP" = "$TARGET_IP" ] \
    || die "Ethernet came up at $NEW_ETH_IP, expected $TARGET_IP"
info "Ethernet now on $NEW_ETH_IP (static)"

# =============================================================================
# PHASE 5 — POST-SWAP VALIDATION
# =============================================================================
# Prove the swap actually works end-to-end before we touch wifi.

section "phase 5: validate post-swap connectivity"

# 5.1  Target IP is held by exactly the Ethernet interface.
CURR_TARGET_IFACE=""
if ! CURR_TARGET_IFACE=$(iface_holding_ip "$TARGET_IP"); then
    die "$TARGET_IP held by multiple interfaces post-swap — refuse"
fi
[ "$CURR_TARGET_IFACE" = "$ETH_IFACE" ] \
    || die "$TARGET_IP held by '${CURR_TARGET_IFACE:-<none>}', expected '$ETH_IFACE'"
info "$TARGET_IP confirmed only on $ETH_IFACE"

# 5.2  Kernel routes outbound (1.1.1.1) via Ethernet.
#
# Polled, not one-shot. ipv4.may-fail=no (phase 2) closes the dual-stack
# early-completion race, but two more sources of lag still exist between
# `nmcli connection up` returning and `ip route get` agreeing that Eth is
# the preferred outbound interface:
#
#   (a) NM's policy engine (nm-policy.c::get_best_active_connection) decides
#       which active connection currently OWNS the default route AFTER the
#       device reaches ACTIVATED, when the set of active connections /
#       metrics changes. The `Default` D-Bus property on Connection.Active
#       is updated by that policy pass — not synchronously at ACTIVATED.
#   (b) Kernel-FIB visibility of routes installed by NM is itself eventually-
#       consistent in places (NM has a workaround, commit f8b2cadf, for
#       missing RTM_DELROUTE events).
#
# 10 seconds is empirically generous: in normal cases the first iteration
# already passes; the loop just exists so we don't fail the swap on a sub-
# second timing artefact.
ROUTE_DEV=""
for _ in $(seq 1 10); do
    ROUTE_DEV=$(ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    [ "$ROUTE_DEV" = "$ETH_IFACE" ] && break
    sleep 1
done
[ "$ROUTE_DEV" = "$ETH_IFACE" ] \
    || die "kernel routes 1.1.1.1 via '${ROUTE_DEV:-<none>}', expected '$ETH_IFACE' (waited 10s after ACTIVATED)"
info "kernel routes 1.1.1.1 via $ETH_IFACE"

# 5.3  Gateway reachable specifically via Ethernet.
ping -c 2 -W 3 -I "$ETH_IFACE" "$GATEWAY" >/dev/null 2>&1 \
    || die "gateway $GATEWAY not reachable bound to $ETH_IFACE"
info "gateway $GATEWAY reachable via $ETH_IFACE"

# 5.4  Internet reachable specifically via Ethernet.
ping -c 2 -W 3 -I "$ETH_IFACE" 1.1.1.1 >/dev/null 2>&1 \
    || ping -c 2 -W 3 -I "$ETH_IFACE" 8.8.8.8 >/dev/null 2>&1 \
    || die "internet not reachable bound to $ETH_IFACE"
info "internet reachable via $ETH_IFACE"

# Swap is verified end-to-end. Disarm rollback. From here on, do not fail.
ROLLBACK_NEEDED=0
trap - ERR

info "swap verified end-to-end — committing"

# =============================================================================
# PHASE 6 — DISABLE WI-FI (committed; warn-only on anomalies)
# =============================================================================
# This section deliberately uses warn() rather than die() for any anomaly: the
# critical path (the swap) has succeeded, and the radio toggle is reversible
# at any time with `sudo nmcli radio wifi on`. A non-zero exit here would
# misrepresent the overall outcome.

section "phase 6: disable Wi-Fi (reboot-persistent, reversible)"

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

if ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 || ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
    info "internet still reachable with Wi-Fi off"
else
    warn "internet check failed after Wi-Fi off — Ethernet route should still work; investigate"
fi

if grep -q '^WirelessEnabled=false' "$NM_STATE_FILE"; then
    info "persistence verified: 'WirelessEnabled=false' written to $NM_STATE_FILE — survives reboot"
else
    warn "expected 'WirelessEnabled=false' in $NM_STATE_FILE; not found — persistence not verified"
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
echo "To re-enable Wi-Fi later:  sudo nmcli radio wifi on"
echo "  (the Wi-Fi profile '$WIFI_CON' is preserved on disk, set to DHCP;"
echo "   it will auto-up on the next radio-on at a DHCP-assigned address,"
echo "   not $TARGET_IP.)"

exit 0
