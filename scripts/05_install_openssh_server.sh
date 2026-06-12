#!/usr/bin/env bash
# scripts/05_install_openssh_server.sh — install OpenSSH for password login.
#
# SSH is the service this box publishes to the internet (over the static IPv4
# from scripts/13). Authentication is by password; public-key auth is turned
# off. The listening socket is pinned to IPv4 only because this box disables
# IPv6 (scripts/12_disable_ipv6.sh) — under socket activation the socket, not
# sshd_config, owns the listening address, so an IPv4-only bind is a ssh.socket
# drop-in.
#
# socket-activation note (Ubuntu 24.04): ssh.socket listens on port 22 from boot
# and spawns ssh.service per connection. So 'systemctl is-active ssh.service'
# reading 'inactive' between connections is correct, not a misconfiguration.
# The Settings -> Sharing -> Remote Login GUI toggle is a redundant no-op under
# socket activation. The script does neither.
#
# Usage:
#   sudo bash scripts/05_install_openssh_server.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

require_root
require_ubuntu_noble
require_sudo_user

TARGET_USER="$SUDO_USER"

# -----------------------------------------------------------------------------
# Pre-flight: validate the account inventory before changing anything
# -----------------------------------------------------------------------------
# Password-only SSH is only safe if the login account actually has a password,
# and if no other account can be reached. Check both up front.
section "pre-flight: account inventory"

# The login account must have a usable (set, unlocked) password — otherwise
# password login either locks you out or, if empty, opens the door.
case "$(passwd -S "$TARGET_USER" 2>/dev/null | awk '{print $2}')" in
    P)  info "account '$TARGET_USER' has a usable password" ;;
    L)  die "account '$TARGET_USER' password is LOCKED — set one first: sudo passwd $TARGET_USER" ;;
    NP) die "account '$TARGET_USER' has NO password — refusing password-only SSH; set one first: sudo passwd $TARGET_USER" ;;
    *)  die "could not determine the password status of '$TARGET_USER'" ;;
esac

# The only human/loginnable account on this single-admin box must be
# $TARGET_USER. Any other account with a real login shell is unexpected — a
# leftover or rogue account is exactly what a post-incident host should refuse
# on. (To run more than one admin, add them deliberately and adjust this check.)
OTHER_USERS="$(awk -F: -v u="$TARGET_USER" \
    '$3 >= 1000 && $3 < 60000 && $1 != u && $7 !~ /(nologin|false)$/ {print $1}' \
    /etc/passwd | tr '\n' ' ')"
OTHER_USERS="${OTHER_USERS% }"
[ -z "$OTHER_USERS" ] \
    || die "unexpected loginnable account(s) besides '$TARGET_USER': $OTHER_USERS — investigate (leftover/rogue?) before exposing SSH"
info "only human account is '$TARGET_USER'"

if dpkg -s openssh-server >/dev/null 2>&1; then
    info "openssh-server is already installed"
else
    section "apt update + install openssh-server"
    apt-get update
    apt-get install -y openssh-server
fi

# -----------------------------------------------------------------------------
# Pin the listening socket to IPv4 only (ssh.socket drop-in)
# -----------------------------------------------------------------------------
# The packaged ssh.socket lists BOTH 0.0.0.0:22 and [::]:22. This box has IPv6
# disabled, so the empty 'ListenStream=' clears that inherited list and the line
# after it re-adds only the IPv4 listener. ('AddressFamily inet' in sshd_config
# would NOT achieve this under socket activation — the socket owns the bind.)
section "pin ssh.socket to IPv4 only"

SOCKET_DROPIN_DIR=/etc/systemd/system/ssh.socket.d
SOCKET_DROPIN="$SOCKET_DROPIN_DIR/10-ipv4-only.conf"
read -r -d '' SOCKET_DROPIN_CONTENT <<'EOF' || true
[Socket]
# Managed by 05_install_openssh_server.sh — pin SSH to IPv4 only (IPv6 is off).
# Empty ListenStream= clears the packaged 0.0.0.0:22 + [::]:22; re-add v4 only.
ListenStream=
ListenStream=0.0.0.0:22
EOF

mkdir -p "$SOCKET_DROPIN_DIR"
if [ -f "$SOCKET_DROPIN" ] && printf '%s\n' "$SOCKET_DROPIN_CONTENT" | cmp -s - "$SOCKET_DROPIN"; then
    info "ssh.socket IPv4-only drop-in already in place"
else
    printf '%s\n' "$SOCKET_DROPIN_CONTENT" > "$SOCKET_DROPIN"
    info "wrote $SOCKET_DROPIN"
    systemctl daemon-reload
    systemctl restart ssh.socket
fi

# -----------------------------------------------------------------------------
# Authentication policy: password on, public-key off
# -----------------------------------------------------------------------------
section "SSH authentication policy (password only)"

AUTH_CONF=/etc/ssh/sshd_config.d/10-auth.conf
read -r -d '' AUTH_CONTENT <<EOF || true
# Managed by 05_install_openssh_server.sh — password authentication, no keys,
# single admin account.
PasswordAuthentication yes
PubkeyAuthentication no
PermitEmptyPasswords no
AllowUsers $TARGET_USER
EOF

if [ -f "$AUTH_CONF" ] && printf '%s\n' "$AUTH_CONTENT" | cmp -s - "$AUTH_CONF"; then
    info "$AUTH_CONF already in place"
else
    printf '%s\n' "$AUTH_CONTENT" > "$AUTH_CONF"
    chmod 0644 "$AUTH_CONF"
    info "wrote $AUTH_CONF"
fi

# sshd -t and -T (below) stat the privilege-separation directory /run/sshd.
# Under socket activation it is ssh.service's RuntimeDirectory= that creates
# /run/sshd, and only when the service first starts — i.e. on the first inbound
# connection — so on a fresh install it does not exist yet and sshd -t would
# abort with "Missing privilege separation directory: /run/sshd". Create it now
# so validation can run; systemd reasserts its owner/mode when ssh.service starts.
[ -d /run/sshd ] || install -d -m 0755 /run/sshd

# Validate, then assert the effective policy (sshd -T reads the merged config).
sshd -t || die "sshd -t rejected the configuration — refusing to continue"
eff() { sshd -T 2>/dev/null | awk -v k="$1" 'tolower($1)==k{print tolower($2); exit}'; }
[ "$(eff passwordauthentication)" = "yes" ] || die "effective PasswordAuthentication is not 'yes'"
[ "$(eff pubkeyauthentication)" = "no" ]    || die "effective PubkeyAuthentication is not 'no'"
[ "$(eff permitemptypasswords)" = "no" ]    || die "effective PermitEmptyPasswords is not 'no'"
allow_val="$(sshd -T 2>/dev/null | awk 'tolower($1)=="allowusers"{print $2; exit}')"
[ "$allow_val" = "$TARGET_USER" ] || die "effective AllowUsers is '$allow_val', expected only '$TARGET_USER'"
info "effective sshd policy verified: password on, public-key off, empty passwords off, only '$TARGET_USER' may log in"

# -----------------------------------------------------------------------------
# Verification (socket state + listening address)
# -----------------------------------------------------------------------------
section "verification"

if ! systemctl is-enabled --quiet ssh.socket; then
    die "ssh.socket is not enabled — it should be enabled by default after install"
fi
require_systemd_active ssh.socket
info "ssh.socket is enabled and active"

if ! ss -tln | grep -qE '(^|[[:space:]])0\.0\.0\.0:22([[:space:]]|$)'; then
    die "port 22 is not listening on 0.0.0.0 after install"
fi
if ss -tln | grep -qE '(^|[[:space:]])\[::\]:22([[:space:]]|$)'; then
    die "port 22 is listening on IPv6 ([::]:22) — the IPv4-only socket pin did not take"
fi
info "port 22 is listening on IPv4 only:"
ss -tln | grep -E ':22([[:space:]]|$)'

section "success"
