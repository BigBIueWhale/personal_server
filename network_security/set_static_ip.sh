#!/bin/bash
set -e

# ===== VALIDATION =====

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Run with sudo"
    exit 1
fi

if ! command -v nmcli &> /dev/null; then
    echo "ERROR: nmcli not found. Is NetworkManager installed?"
    exit 1
fi

if ! systemctl is-active --quiet NetworkManager; then
    echo "ERROR: NetworkManager is not running"
    exit 1
fi

WIFI_CON=$(nmcli -t -f NAME,TYPE connection show | grep wireless | cut -d: -f1 | head -n1)

if [ -z "$WIFI_CON" ]; then
    echo "ERROR: No WiFi connection found"
    exit 1
fi

WIFI_STATE=$(nmcli -t -f NAME,STATE connection show --active | grep "$WIFI_CON" | cut -d: -f2)
if [ "$WIFI_STATE" != "activated" ]; then
    echo "ERROR: WiFi '$WIFI_CON' is not currently connected"
    exit 1
fi

CURRENT_GW=$(ip route | grep default | awk '{print $3}' | head -n1)
if [ "$CURRENT_GW" != "10.0.0.138" ]; then
    echo "ERROR: Expected gateway 10.0.0.138, found '$CURRENT_GW'"
    exit 1
fi

CURRENT_IP=$(ip -4 addr show | grep "inet 10\." | awk '{print $2}' | cut -d/ -f1)
if [ "$CURRENT_IP" != "10.0.0.200" ]; then
    ping -c 1 -W 1 10.0.0.200 &> /dev/null
    if [ $? -eq 0 ]; then
        echo "ERROR: 10.0.0.200 is already in use by another device"
        exit 1
    fi
fi

# ===== APPLY CHANGES =====

echo "Validation passed."
echo "  WiFi: $WIFI_CON"
echo "  Current IP: $CURRENT_IP"
echo ""
echo "Applying static IP 10.0.0.200..."

nmcli connection modify "$WIFI_CON" \
    ipv4.method manual \
    ipv4.addresses 10.0.0.200/24 \
    ipv4.gateway 10.0.0.138 \
    ipv4.dns "10.0.0.138 8.8.8.8"

nmcli connection down "$WIFI_CON"
sleep 2
nmcli connection up "$WIFI_CON"

# ===== VERIFY =====

echo ""
echo "Verifying..."

NEW_IP=$(ip -4 addr show | grep "inet 10\." | awk '{print $2}' | cut -d/ -f1)
if [ "$NEW_IP" != "10.0.0.200" ]; then
    echo "WARNING: Expected 10.0.0.200, got $NEW_IP"
    exit 1
fi

echo "  New IP: $NEW_IP"

if ping -c 2 google.com &> /dev/null; then
    echo "  Internet: OK"
else
    echo "  Internet: FAILED"
    echo ""
    echo "Rolling back to DHCP..."
    nmcli connection modify "$WIFI_CON" ipv4.method auto
    nmcli connection down "$WIFI_CON"
    sleep 2
    nmcli connection up "$WIFI_CON"
    echo "Rolled back. Check your settings."
    exit 1
fi

echo ""
echo "SUCCESS. Now update router DMZ to 10.0.0.200"
