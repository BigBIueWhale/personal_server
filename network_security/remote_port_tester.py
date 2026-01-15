#!/usr/bin/env python3
"""
Comprehensive Remote Port Security Tester

This script performs thorough network security testing of a personal server from a
remote location. It verifies that:
  - Expected services (SSH, RustDesk) are accessible
  - VMware ports are properly blocked by firewall rules
  - Localhost-only services are not accidentally exposed
  - No unexpected services are listening on any port
  - Both IPv4 and IPv6 are properly secured

Designed for a DMZ-exposed Ubuntu 24.04 server with:
  - OpenSSH Server on port 22
  - RustDesk on ports 21118/tcp and 21119/udp
  - VMware Workstation Pro (ports blocked by iptables)
  - OpenWebUI, Ollama, TeamViewer, CUPS (localhost-only)

Usage:
    python3 remote_port_tester.py --target IP_ADDRESS
    python3 remote_port_tester.py --target IP_ADDRESS --quick
    python3 remote_port_tester.py --target IP_ADDRESS --ipv6 IPV6_ADDRESS

Exit codes:
    0 = All security checks passed
    1 = Warnings present (non-critical)
    2 = Security issues detected (critical failures)
    3 = Connectivity validation failed (cannot reach target or no internet)
"""

import argparse
import concurrent.futures
import socket
import sys
import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Optional


# =============================================================================
# Connectivity validation - must pass before running tests
# =============================================================================

def check_local_ipv4_connectivity() -> tuple[bool, str]:
    """
    Check if this machine has working IPv4 internet connectivity.

    Tests by attempting to connect to well-known public DNS servers.
    Returns (success, message).
    """
    # Test multiple endpoints in case one is down
    test_targets = [
        ("8.8.8.8", 53, "Google DNS"),
        ("1.1.1.1", 53, "Cloudflare DNS"),
        ("208.67.222.222", 53, "OpenDNS"),
    ]

    for ip, port, name in test_targets:
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(5.0)
            sock.connect((ip, port))
            sock.close()
            return True, f"IPv4 connectivity verified via {name} ({ip})"
        except Exception:
            continue

    return False, "No IPv4 internet connectivity - cannot reach any public DNS server"


def check_local_ipv6_connectivity() -> tuple[bool, str]:
    """
    Check if this machine has working IPv6 internet connectivity.

    Tests by attempting to connect to well-known public IPv6 DNS servers.
    Returns (success, message).
    """
    # Test multiple IPv6 endpoints
    test_targets = [
        ("2001:4860:4860::8888", 53, "Google DNS IPv6"),
        ("2606:4700:4700::1111", 53, "Cloudflare DNS IPv6"),
        ("2620:119:35::35", 53, "OpenDNS IPv6"),
    ]

    for ip, port, name in test_targets:
        try:
            sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
            sock.settimeout(5.0)
            sock.connect((ip, port))
            sock.close()
            return True, f"IPv6 connectivity verified via {name} ({ip})"
        except Exception:
            continue

    return False, "No IPv6 internet connectivity - cannot reach any public IPv6 DNS server"


def check_target_reachable_ipv4(target: str) -> tuple[bool, str]:
    """
    Check if the target IPv4 address is reachable (responds to TCP on port 22 or times out).

    We don't require SSH to be open - we just verify we can attempt a connection
    without immediate network errors (like "no route to host").
    """
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(10.0)

        # Use connect() instead of connect_ex() for clearer exception handling
        try:
            sock.connect((target, 22))
            sock.close()
            return True, f"Target {target} is reachable (port 22 open)"
        except socket.timeout:
            sock.close()
            return True, f"Target {target} is reachable (connection timed out - filtered)"
        except ConnectionRefusedError:
            sock.close()
            return True, f"Target {target} is reachable (port 22 refused - closed but host is up)"
        except OSError as e:
            sock.close()
            # Network unreachable, host unreachable, no route to host
            if e.errno in (101, 113, 65):  # ENETUNREACH, EHOSTUNREACH, ENOPROTOOPT
                return False, f"Target {target} not reachable: {e.strerror}"
            # Other errors (like ECONNREFUSED=111) mean host is reachable
            if e.errno == 111:
                return True, f"Target {target} is reachable (connection refused)"
            # For other errors, assume reachable if we got past the routing
            return True, f"Target {target} appears reachable (got response: {e.strerror})"

    except socket.gaierror as e:
        return False, f"Target {target} DNS/address error: {e}"
    except Exception as e:
        return False, f"Target {target} connectivity check failed: {e}"
    finally:
        try:
            sock.close()
        except Exception:
            pass


def check_target_reachable_ipv6(target: str) -> tuple[bool, str]:
    """
    Check if the target IPv6 address is reachable.
    """
    try:
        sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        sock.settimeout(10.0)

        try:
            sock.connect((target, 22))
            sock.close()
            return True, f"Target {target} is reachable via IPv6 (port 22 open)"
        except socket.timeout:
            sock.close()
            return True, f"Target {target} is reachable via IPv6 (connection timed out - filtered)"
        except ConnectionRefusedError:
            sock.close()
            return True, f"Target {target} is reachable via IPv6 (port 22 refused - closed but host is up)"
        except OSError as e:
            sock.close()
            if e.errno in (101, 113, 65):  # ENETUNREACH, EHOSTUNREACH, ENOPROTOOPT
                return False, f"Target {target} not reachable via IPv6: {e.strerror}"
            if e.errno == 111:
                return True, f"Target {target} is reachable via IPv6 (connection refused)"
            return True, f"Target {target} appears reachable via IPv6 (got response: {e.strerror})"

    except socket.gaierror as e:
        return False, f"Target {target} IPv6 DNS/address error: {e}"
    except Exception as e:
        return False, f"Target {target} IPv6 connectivity check failed: {e}"
    finally:
        try:
            sock.close()
        except Exception:
            pass


def validate_connectivity(target_ipv4: str, target_ipv6: Optional[str] = None) -> bool:
    """
    Validate network connectivity before running tests.

    Requirements:
    1. Local machine MUST have IPv4 internet connectivity
    2. Target IPv4 MUST be reachable
    3. If IPv6 target specified:
       - Local machine MUST have IPv6 internet connectivity
       - Target IPv6 MUST be reachable

    Returns True if all checks pass, exits with error otherwise.
    """
    print("=" * 70)
    print("CONNECTIVITY VALIDATION")
    print("=" * 70)
    print()

    all_passed = True

    # Check 1: Local IPv4 connectivity
    print("Checking local IPv4 internet connectivity...")
    ipv4_ok, ipv4_msg = check_local_ipv4_connectivity()
    if ipv4_ok:
        print(f"\033[92m[PASS]\033[0m {ipv4_msg}")
    else:
        print(f"\033[91m[FAIL]\033[0m {ipv4_msg}")
        all_passed = False

    # Check 2: Target IPv4 reachability
    print(f"Checking target {target_ipv4} reachability...")
    target_v4_ok, target_v4_msg = check_target_reachable_ipv4(target_ipv4)
    if target_v4_ok:
        print(f"\033[92m[PASS]\033[0m {target_v4_msg}")
    else:
        print(f"\033[91m[FAIL]\033[0m {target_v4_msg}")
        all_passed = False

    # Check 3: IPv6 (only if target specified)
    if target_ipv6:
        print()
        print("IPv6 target specified - validating IPv6 connectivity...")
        print()

        # Check 3a: Local IPv6 connectivity
        print("Checking local IPv6 internet connectivity...")
        ipv6_ok, ipv6_msg = check_local_ipv6_connectivity()
        if ipv6_ok:
            print(f"\033[92m[PASS]\033[0m {ipv6_msg}")
        else:
            print(f"\033[91m[FAIL]\033[0m {ipv6_msg}")
            print()
            print("\033[91mERROR: IPv6 target specified but this machine has no IPv6 connectivity.\033[0m")
            print("Either:")
            print("  1. Remove the --ipv6 argument to skip IPv6 testing")
            print("  2. Run this script from a machine with IPv6 internet access")
            all_passed = False

        # Check 3b: Target IPv6 reachability (only if local IPv6 works)
        if ipv6_ok:
            print(f"Checking target {target_ipv6} reachability via IPv6...")
            target_v6_ok, target_v6_msg = check_target_reachable_ipv6(target_ipv6)
            if target_v6_ok:
                print(f"\033[92m[PASS]\033[0m {target_v6_msg}")
            else:
                print(f"\033[91m[FAIL]\033[0m {target_v6_msg}")
                all_passed = False

    print()

    if not all_passed:
        print("\033[91m" + "=" * 70 + "\033[0m")
        print("\033[91mCONNECTIVITY VALIDATION FAILED - CANNOT PROCEED\033[0m")
        print("\033[91m" + "=" * 70 + "\033[0m")
        print()
        print("Fix the connectivity issues above before running security tests.")
        return False

    print("\033[92m[OK]\033[0m All connectivity checks passed - proceeding with security tests")
    print()
    return True


# =============================================================================
# Configuration: Expected network security state
# =============================================================================

class ExpectedState(Enum):
    """Expected state of a port when tested from remote."""
    OPEN = "OPEN"           # Service should accept connections
    BLOCKED = "BLOCKED"     # Firewall DROP rule (timeout/filtered)
    CLOSED = "CLOSED"       # No service listening (RST/refused) or filtered


class ActualState(Enum):
    """Actual observed state of a port."""
    OPEN = "OPEN"           # Connection succeeded
    CLOSED = "CLOSED"       # Connection refused (RST) or ICMP unreachable
    FILTERED = "FILTERED"   # Timeout - packet dropped
    UNKNOWN = "UNKNOWN"     # Could not determine


class Protocol(Enum):
    TCP = "TCP"
    UDP = "UDP"


class Severity(Enum):
    """Severity of a test result."""
    CRITICAL = "CRITICAL"   # Security vulnerability
    WARNING = "WARNING"     # Potential issue
    INFO = "INFO"           # Informational


@dataclass
class PortSpec:
    """Specification for a port to test."""
    port: int
    protocol: Protocol
    service: str
    expected: ExpectedState
    description: str
    severity_if_wrong: Severity = Severity.CRITICAL


# -----------------------------------------------------------------------------
# Services that MUST be accessible from the internet
# -----------------------------------------------------------------------------
MUST_BE_OPEN = [
    PortSpec(
        port=22,
        protocol=Protocol.TCP,
        service="OpenSSH",
        expected=ExpectedState.OPEN,
        description="SSH server for remote administration",
        severity_if_wrong=Severity.CRITICAL,
    ),
    PortSpec(
        port=21118,
        protocol=Protocol.TCP,
        service="RustDesk",
        expected=ExpectedState.OPEN,
        description="RustDesk direct IP access port",
        severity_if_wrong=Severity.CRITICAL,
    ),
    PortSpec(
        port=21119,
        protocol=Protocol.UDP,
        service="RustDesk",
        expected=ExpectedState.OPEN,
        description="RustDesk signaling/relay port",
        severity_if_wrong=Severity.WARNING,  # UDP might not respond to probes
    ),
]

# -----------------------------------------------------------------------------
# VMware ports that MUST be blocked by iptables DROP rules
# These services ARE listening locally but firewall blocks external access
# -----------------------------------------------------------------------------
MUST_BE_BLOCKED_VMWARE = [
    PortSpec(
        port=902,
        protocol=Protocol.TCP,
        service="VMware Auth Daemon",
        expected=ExpectedState.BLOCKED,
        description="VMware Authentication Daemon - CRITICAL if exposed (CVE-2025-22224, brute-force attacks)",
        severity_if_wrong=Severity.CRITICAL,
    ),
    PortSpec(
        port=902,
        protocol=Protocol.UDP,
        service="VMware Auth Daemon",
        expected=ExpectedState.BLOCKED,
        description="VMware console heartbeat/screen data",
        severity_if_wrong=Severity.CRITICAL,
    ),
    PortSpec(
        port=912,
        protocol=Protocol.TCP,
        service="VMware authd",
        expected=ExpectedState.BLOCKED,
        description="VMware Authorization Service (secondary port)",
        severity_if_wrong=Severity.CRITICAL,
    ),
    PortSpec(
        port=8222,
        protocol=Protocol.TCP,
        service="VMware hostd",
        expected=ExpectedState.BLOCKED,
        description="VMware Management Interface (HTTP - plaintext credentials!)",
        severity_if_wrong=Severity.CRITICAL,
    ),
    PortSpec(
        port=8333,
        protocol=Protocol.TCP,
        service="VMware hostd",
        expected=ExpectedState.BLOCKED,
        description="VMware Management Interface (HTTPS)",
        severity_if_wrong=Severity.CRITICAL,
    ),
]

# -----------------------------------------------------------------------------
# Services that should be localhost-only (must NOT respond externally)
# If these respond, it means they're misconfigured to bind to 0.0.0.0
# -----------------------------------------------------------------------------
MUST_NOT_BE_EXPOSED = [
    PortSpec(
        port=3000,
        protocol=Protocol.TCP,
        service="OpenWebUI",
        expected=ExpectedState.CLOSED,
        description="OpenWebUI should be bound to 127.0.0.1 only",
        severity_if_wrong=Severity.CRITICAL,
    ),
    PortSpec(
        port=11434,
        protocol=Protocol.TCP,
        service="Ollama",
        expected=ExpectedState.CLOSED,
        description="Ollama API should be bound to Docker bridge (172.17.0.1) only",
        severity_if_wrong=Severity.CRITICAL,
    ),
    PortSpec(
        port=5939,
        protocol=Protocol.TCP,
        service="TeamViewer",
        expected=ExpectedState.CLOSED,
        description="TeamViewer daemon should be bound to 127.0.0.1 only",
        severity_if_wrong=Severity.CRITICAL,
    ),
    PortSpec(
        port=631,
        protocol=Protocol.TCP,
        service="CUPS",
        expected=ExpectedState.CLOSED,
        description="CUPS printing should be bound to 127.0.0.1 only",
        severity_if_wrong=Severity.WARNING,
    ),
    PortSpec(
        port=443,
        protocol=Protocol.TCP,
        service="VMware Shared VMs",
        expected=ExpectedState.CLOSED,
        description="VMware Shared VMs feature (removed in 16.2.0, should not exist)",
        severity_if_wrong=Severity.CRITICAL,
    ),
    PortSpec(
        port=5353,
        protocol=Protocol.UDP,
        service="Avahi/mDNS",
        expected=ExpectedState.CLOSED,
        description="Avahi mDNS should be disabled on DMZ host",
        severity_if_wrong=Severity.WARNING,
    ),
    PortSpec(
        port=53,
        protocol=Protocol.UDP,
        service="DNS",
        expected=ExpectedState.CLOSED,
        description="systemd-resolved should be bound to 127.0.0.53 only",
        severity_if_wrong=Severity.CRITICAL,
    ),
    PortSpec(
        port=53,
        protocol=Protocol.TCP,
        service="DNS",
        expected=ExpectedState.CLOSED,
        description="DNS TCP should not be exposed",
        severity_if_wrong=Severity.CRITICAL,
    ),
]

# -----------------------------------------------------------------------------
# VMware VNC ports - only used if explicitly configured per-VM
# Should not be listening unless user specifically enabled VNC on a VM
# -----------------------------------------------------------------------------
VMWARE_VNC_PORTS = [
    PortSpec(
        port=port,
        protocol=Protocol.TCP,
        service=f"VMware VNC (VM display {port - 5900})",
        expected=ExpectedState.CLOSED,
        description=f"VMware VM VNC port - should not be exposed unless intentionally configured",
        severity_if_wrong=Severity.CRITICAL,
    )
    for port in range(5900, 5910)  # Check first 10 potential VNC ports
]

# -----------------------------------------------------------------------------
# VS Code / Code Server / IDE ports - CRITICAL security risk if exposed
# These are commonly accidentally left running and bound to 0.0.0.0
# -----------------------------------------------------------------------------
VSCODE_IDE_PORTS = [
    # code-server (coder.com) - VS Code in browser
    PortSpec(8080, Protocol.TCP, "code-server", ExpectedState.CLOSED,
             "code-server default port - VS Code in browser, CRITICAL if exposed"),
    PortSpec(8443, Protocol.TCP, "code-server (Docker)", ExpectedState.CLOSED,
             "code-server LinuxServer Docker default - VS Code in browser"),

    # openvscode-server (Gitpod) - VS Code in browser
    PortSpec(3000, Protocol.TCP, "openvscode-server", ExpectedState.CLOSED,
             "openvscode-server/Gitpod default port - VS Code in browser, shell access!"),

    # VS Code internal/language servers
    PortSpec(9000, Protocol.TCP, "VS Code Language Server", ExpectedState.CLOSED,
             "VS Code language server port (conflicts with xdebug) - should be localhost only"),

    # Jupyter Notebook/Lab - often used with VS Code
    PortSpec(8888, Protocol.TCP, "Jupyter Notebook", ExpectedState.CLOSED,
             "Jupyter Notebook/Lab default - arbitrary code execution if exposed!"),
    PortSpec(8889, Protocol.TCP, "Jupyter Notebook Alt", ExpectedState.CLOSED,
             "Jupyter Notebook alternative port"),

    # JupyterHub
    PortSpec(8081, Protocol.TCP, "JupyterHub", ExpectedState.CLOSED,
             "JupyterHub proxy - multi-user Jupyter, CRITICAL if exposed"),

    # Theia IDE (Eclipse)
    PortSpec(3030, Protocol.TCP, "Theia IDE", ExpectedState.CLOSED,
             "Eclipse Theia IDE default port - VS Code alternative in browser"),

    # Coder enterprise / v2
    PortSpec(3001, Protocol.TCP, "Coder Dashboard", ExpectedState.CLOSED,
             "Coder v2 dashboard - enterprise code-server"),
    PortSpec(7080, Protocol.TCP, "Coder", ExpectedState.CLOSED,
             "Coder enterprise default port"),

    # VS Code Live Share
    PortSpec(5000, Protocol.TCP, "VS Code Live Share", ExpectedState.CLOSED,
             "VS Code Live Share - collaborative editing, should not be public"),

    # Debug ports commonly used
    PortSpec(5678, Protocol.TCP, "Python debugpy", ExpectedState.CLOSED,
             "Python debugpy/debugger default - VS Code Python debugging"),
    PortSpec(9229, Protocol.TCP, "Node.js Inspector", ExpectedState.CLOSED,
             "Node.js debugger/inspector - remote code execution if exposed!"),
    PortSpec(9222, Protocol.TCP, "Chrome DevTools", ExpectedState.CLOSED,
             "Chrome DevTools Protocol - browser debugging, RCE risk"),
    PortSpec(9230, Protocol.TCP, "Node.js Inspector Alt", ExpectedState.CLOSED,
             "Node.js inspector alternative port"),

    # PHP Xdebug
    PortSpec(9003, Protocol.TCP, "Xdebug", ExpectedState.CLOSED,
             "PHP Xdebug default (v3) - debugger should be localhost only"),

    # Go Delve debugger
    PortSpec(2345, Protocol.TCP, "Go Delve", ExpectedState.CLOSED,
             "Go Delve debugger default - should be localhost only"),

    # Ruby debug
    PortSpec(1234, Protocol.TCP, "Ruby Debug", ExpectedState.CLOSED,
             "Ruby debugger common port"),

    # Java Debug Wire Protocol
    PortSpec(5005, Protocol.TCP, "Java JDWP", ExpectedState.CLOSED,
             "Java Debug Wire Protocol - remote code execution if exposed!"),

    # .NET debugger
    PortSpec(4024, Protocol.TCP, ".NET Debugger", ExpectedState.CLOSED,
             ".NET/Mono debugger port"),

    # Language servers that might accidentally bind to 0.0.0.0
    PortSpec(2087, Protocol.TCP, "LSP Server", ExpectedState.CLOSED,
             "Language Server Protocol common port"),

    # Webpack dev server
    PortSpec(8081, Protocol.TCP, "Webpack Dev Server", ExpectedState.CLOSED,
             "Webpack dev server - often misconfigured to 0.0.0.0"),

    # Vite dev server
    PortSpec(5173, Protocol.TCP, "Vite Dev Server", ExpectedState.CLOSED,
             "Vite dev server default - modern frontend tooling"),
    PortSpec(5174, Protocol.TCP, "Vite Dev Server Alt", ExpectedState.CLOSED,
             "Vite dev server alternative port"),

    # Parcel bundler
    PortSpec(1234, Protocol.TCP, "Parcel Dev Server", ExpectedState.CLOSED,
             "Parcel bundler dev server default"),

    # Create React App / Next.js
    PortSpec(3001, Protocol.TCP, "React/Next.js Dev", ExpectedState.CLOSED,
             "Create React App / Next.js dev server alternative"),

    # Angular CLI
    PortSpec(4200, Protocol.TCP, "Angular Dev Server", ExpectedState.CLOSED,
             "Angular CLI dev server default"),
    PortSpec(4201, Protocol.TCP, "Angular Dev Server Alt", ExpectedState.CLOSED,
             "Angular CLI dev server alternative"),

    # Vue CLI
    PortSpec(8082, Protocol.TCP, "Vue Dev Server", ExpectedState.CLOSED,
             "Vue CLI dev server alternative port"),

    # Storybook
    PortSpec(6006, Protocol.TCP, "Storybook", ExpectedState.CLOSED,
             "Storybook UI component dev server"),
    PortSpec(6007, Protocol.TCP, "Storybook Alt", ExpectedState.CLOSED,
             "Storybook alternative port"),

    # Hot Module Replacement websocket ports
    PortSpec(24678, Protocol.TCP, "Vite HMR", ExpectedState.CLOSED,
             "Vite HMR WebSocket port"),
]

# -----------------------------------------------------------------------------
# Common dangerous ports that should NEVER be open on a public server
# These catch mistakes like accidentally running test services
# -----------------------------------------------------------------------------
COMMON_DANGEROUS_PORTS = [
    # Database ports
    PortSpec(3306, Protocol.TCP, "MySQL", ExpectedState.CLOSED, "MySQL database - should never be public"),
    PortSpec(5432, Protocol.TCP, "PostgreSQL", ExpectedState.CLOSED, "PostgreSQL database - should never be public"),
    PortSpec(27017, Protocol.TCP, "MongoDB", ExpectedState.CLOSED, "MongoDB - should never be public"),
    PortSpec(6379, Protocol.TCP, "Redis", ExpectedState.CLOSED, "Redis - should never be public"),
    PortSpec(9200, Protocol.TCP, "Elasticsearch", ExpectedState.CLOSED, "Elasticsearch - should never be public"),
    PortSpec(9300, Protocol.TCP, "Elasticsearch", ExpectedState.CLOSED, "Elasticsearch cluster - should never be public"),

    # Message queues
    PortSpec(5672, Protocol.TCP, "RabbitMQ", ExpectedState.CLOSED, "RabbitMQ AMQP - should never be public"),
    PortSpec(15672, Protocol.TCP, "RabbitMQ Mgmt", ExpectedState.CLOSED, "RabbitMQ management - should never be public"),
    PortSpec(9092, Protocol.TCP, "Kafka", ExpectedState.CLOSED, "Kafka - should never be public"),

    # Admin interfaces
    PortSpec(8080, Protocol.TCP, "HTTP Alt", ExpectedState.CLOSED, "Alternative HTTP - common for dev servers"),
    PortSpec(8443, Protocol.TCP, "HTTPS Alt", ExpectedState.CLOSED, "Alternative HTTPS - common for dev servers"),
    PortSpec(9090, Protocol.TCP, "Prometheus", ExpectedState.CLOSED, "Prometheus - should never be public"),
    PortSpec(3000, Protocol.TCP, "Grafana/Dev", ExpectedState.CLOSED, "Grafana or dev server - should never be public"),
    PortSpec(8000, Protocol.TCP, "Dev Server", ExpectedState.CLOSED, "Common development server port"),
    PortSpec(4000, Protocol.TCP, "Dev Server", ExpectedState.CLOSED, "Common development server port"),
    PortSpec(5000, Protocol.TCP, "Dev Server", ExpectedState.CLOSED, "Flask/dev server - should never be public"),

    # Remote access (besides SSH)
    PortSpec(23, Protocol.TCP, "Telnet", ExpectedState.CLOSED, "Telnet - insecure, should never be used"),
    PortSpec(3389, Protocol.TCP, "RDP", ExpectedState.CLOSED, "Remote Desktop Protocol - Windows only"),
    PortSpec(5900, Protocol.TCP, "VNC", ExpectedState.CLOSED, "VNC - should not be directly exposed"),
    PortSpec(5901, Protocol.TCP, "VNC", ExpectedState.CLOSED, "VNC display :1"),

    # File sharing
    PortSpec(21, Protocol.TCP, "FTP", ExpectedState.CLOSED, "FTP - insecure file transfer"),
    PortSpec(445, Protocol.TCP, "SMB", ExpectedState.CLOSED, "SMB/CIFS - Windows file sharing, high risk"),
    PortSpec(139, Protocol.TCP, "NetBIOS", ExpectedState.CLOSED, "NetBIOS Session - Windows networking"),
    PortSpec(2049, Protocol.TCP, "NFS", ExpectedState.CLOSED, "NFS - Network File System"),
    PortSpec(111, Protocol.TCP, "RPCBind", ExpectedState.CLOSED, "RPC portmapper - NFS related"),

    # Mail (unless intentionally running mail server)
    PortSpec(25, Protocol.TCP, "SMTP", ExpectedState.CLOSED, "SMTP - mail server"),
    PortSpec(587, Protocol.TCP, "SMTP Submission", ExpectedState.CLOSED, "SMTP submission"),
    PortSpec(110, Protocol.TCP, "POP3", ExpectedState.CLOSED, "POP3 mail"),
    PortSpec(143, Protocol.TCP, "IMAP", ExpectedState.CLOSED, "IMAP mail"),

    # Docker
    PortSpec(2375, Protocol.TCP, "Docker", ExpectedState.CLOSED, "Docker API unencrypted - CRITICAL if exposed"),
    PortSpec(2376, Protocol.TCP, "Docker TLS", ExpectedState.CLOSED, "Docker API TLS - should not be public"),
    PortSpec(2377, Protocol.TCP, "Docker Swarm", ExpectedState.CLOSED, "Docker Swarm management"),

    # Kubernetes
    PortSpec(6443, Protocol.TCP, "K8s API", ExpectedState.CLOSED, "Kubernetes API server"),
    PortSpec(10250, Protocol.TCP, "Kubelet", ExpectedState.CLOSED, "Kubernetes Kubelet API"),
    PortSpec(10255, Protocol.TCP, "Kubelet RO", ExpectedState.CLOSED, "Kubernetes Kubelet read-only"),
    PortSpec(2379, Protocol.TCP, "etcd", ExpectedState.CLOSED, "etcd client - Kubernetes backend"),
    PortSpec(2380, Protocol.TCP, "etcd peer", ExpectedState.CLOSED, "etcd peer communication"),

    # Misc services
    PortSpec(6666, Protocol.TCP, "IRC/Backdoor", ExpectedState.CLOSED, "Common backdoor port"),
    PortSpec(6667, Protocol.TCP, "IRC", ExpectedState.CLOSED, "IRC - sometimes used for botnets"),
    PortSpec(4444, Protocol.TCP, "Metasploit", ExpectedState.CLOSED, "Common Metasploit/backdoor port"),
    PortSpec(1433, Protocol.TCP, "MSSQL", ExpectedState.CLOSED, "Microsoft SQL Server"),
    PortSpec(1521, Protocol.TCP, "Oracle", ExpectedState.CLOSED, "Oracle database"),
    PortSpec(11211, Protocol.TCP, "Memcached", ExpectedState.CLOSED, "Memcached - DDoS amplification risk"),
    PortSpec(11211, Protocol.UDP, "Memcached", ExpectedState.CLOSED, "Memcached UDP - severe DDoS amplification"),

    # SNMP
    PortSpec(161, Protocol.UDP, "SNMP", ExpectedState.CLOSED, "SNMP - information disclosure risk"),
    PortSpec(162, Protocol.UDP, "SNMP Trap", ExpectedState.CLOSED, "SNMP traps"),

    # NTP (can be used for amplification attacks)
    PortSpec(123, Protocol.UDP, "NTP", ExpectedState.CLOSED, "NTP - DDoS amplification risk if misconfigured"),

    # LDAP
    PortSpec(389, Protocol.TCP, "LDAP", ExpectedState.CLOSED, "LDAP directory"),
    PortSpec(636, Protocol.TCP, "LDAPS", ExpectedState.CLOSED, "LDAP over SSL"),

    # X11
    PortSpec(6000, Protocol.TCP, "X11", ExpectedState.CLOSED, "X11 display - should never be exposed"),
    PortSpec(6001, Protocol.TCP, "X11", ExpectedState.CLOSED, "X11 display :1"),
]

# Remove duplicates from VSCODE_IDE_PORTS that are already in other lists
_already_specified_ports = set()
for spec in MUST_BE_OPEN + MUST_BE_BLOCKED_VMWARE + MUST_NOT_BE_EXPOSED + VMWARE_VNC_PORTS:
    _already_specified_ports.add((spec.port, spec.protocol))
VSCODE_IDE_PORTS = [
    spec for spec in VSCODE_IDE_PORTS
    if (spec.port, spec.protocol) not in _already_specified_ports
]

# Remove duplicates from COMMON_DANGEROUS_PORTS that are already in other lists
for spec in VSCODE_IDE_PORTS:
    _already_specified_ports.add((spec.port, spec.protocol))
COMMON_DANGEROUS_PORTS = [
    spec for spec in COMMON_DANGEROUS_PORTS
    if (spec.port, spec.protocol) not in _already_specified_ports
]


# =============================================================================
# Test result tracking
# =============================================================================

@dataclass
class TestResult:
    """Result of testing a single port."""
    spec: PortSpec
    actual: ActualState
    passed: bool
    message: str
    banner: Optional[str] = None
    response_time_ms: Optional[float] = None


@dataclass
class ScanResult:
    """Result of a discovery scan finding."""
    port: int
    protocol: Protocol
    state: ActualState
    banner: Optional[str] = None


@dataclass
class TestSummary:
    """Summary of all test results."""
    target_ipv4: str
    target_ipv6: Optional[str]
    start_time: str
    end_time: str
    duration_seconds: float

    critical_failures: list[TestResult] = field(default_factory=list)
    warnings: list[TestResult] = field(default_factory=list)
    passed: list[TestResult] = field(default_factory=list)

    unexpected_open_ports: list[ScanResult] = field(default_factory=list)

    ipv6_critical_failures: list[TestResult] = field(default_factory=list)
    ipv6_warnings: list[TestResult] = field(default_factory=list)


# =============================================================================
# Port testing functions
# =============================================================================

def test_tcp_port(host: str, port: int, timeout: float = 3.0) -> tuple[ActualState, Optional[str], float]:
    """
    Test TCP connectivity to host:port.

    Returns:
        tuple of (ActualState, banner_or_none, response_time_ms)
    """
    start = time.time()
    sock = socket.socket(socket.AF_INET6 if ':' in host else socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)

    try:
        sock.connect((host, port))
        elapsed_ms = (time.time() - start) * 1000

        # Try to grab banner (optional, quick timeout)
        banner = None
        try:
            sock.settimeout(1.0)
            data = sock.recv(1024)
            if data:
                try:
                    banner = data.decode('utf-8', errors='replace').strip()[:100]
                except Exception:
                    banner = f"[binary: {len(data)} bytes]"
        except (socket.timeout, Exception):
            pass

        sock.close()
        return ActualState.OPEN, banner, elapsed_ms

    except socket.timeout:
        elapsed_ms = (time.time() - start) * 1000
        return ActualState.FILTERED, None, elapsed_ms

    except ConnectionRefusedError:
        elapsed_ms = (time.time() - start) * 1000
        return ActualState.CLOSED, None, elapsed_ms

    except OSError as e:
        elapsed_ms = (time.time() - start) * 1000
        if e.errno in (111, 113, 101):  # ECONNREFUSED, EHOSTUNREACH, ENETUNREACH
            return ActualState.CLOSED, None, elapsed_ms
        return ActualState.UNKNOWN, str(e), elapsed_ms

    except Exception as e:
        elapsed_ms = (time.time() - start) * 1000
        return ActualState.UNKNOWN, str(e), elapsed_ms

    finally:
        try:
            sock.close()
        except Exception:
            pass


def test_udp_port(host: str, port: int, timeout: float = 3.0) -> tuple[ActualState, Optional[str], float]:
    """
    Test UDP connectivity to host:port.

    UDP is connectionless - we send a probe and check for response/ICMP error.

    Returns:
        tuple of (ActualState, response_or_none, response_time_ms)
    """
    start = time.time()
    sock = socket.socket(socket.AF_INET6 if ':' in host else socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)

    try:
        # Send probe packet
        probe = b'\x00' * 8
        sock.sendto(probe, (host, port))

        try:
            data, addr = sock.recvfrom(1024)
            elapsed_ms = (time.time() - start) * 1000
            if data:
                try:
                    response = data.decode('utf-8', errors='replace')[:50]
                except Exception:
                    response = f"[binary: {len(data)} bytes]"
                return ActualState.OPEN, response, elapsed_ms
            return ActualState.OPEN, None, elapsed_ms

        except socket.timeout:
            elapsed_ms = (time.time() - start) * 1000
            # No response - could be filtered OR open but ignoring probe
            return ActualState.FILTERED, None, elapsed_ms

        except ConnectionRefusedError:
            elapsed_ms = (time.time() - start) * 1000
            # ICMP port unreachable
            return ActualState.CLOSED, None, elapsed_ms

        except OSError as e:
            elapsed_ms = (time.time() - start) * 1000
            if e.errno == 111:  # ECONNREFUSED
                return ActualState.CLOSED, None, elapsed_ms
            return ActualState.UNKNOWN, str(e), elapsed_ms

    except Exception as e:
        elapsed_ms = (time.time() - start) * 1000
        return ActualState.UNKNOWN, str(e), elapsed_ms

    finally:
        try:
            sock.close()
        except Exception:
            pass


def test_port(host: str, spec: PortSpec, timeout: float = 3.0) -> TestResult:
    """Test a single port against its specification."""
    if spec.protocol == Protocol.TCP:
        actual, banner, response_time = test_tcp_port(host, spec.port, timeout)
    else:
        actual, banner, response_time = test_udp_port(host, spec.port, timeout)

    # Determine if test passed
    passed = False
    if spec.expected == ExpectedState.OPEN:
        passed = (actual == ActualState.OPEN)
    elif spec.expected == ExpectedState.BLOCKED:
        # BLOCKED means firewall DROP rule - expect FILTERED (timeout)
        passed = (actual == ActualState.FILTERED)
    elif spec.expected == ExpectedState.CLOSED:
        # CLOSED means not listening - expect CLOSED or FILTERED
        passed = (actual in (ActualState.CLOSED, ActualState.FILTERED))

    # Generate message
    if passed:
        message = f"Port {spec.port}/{spec.protocol.value} is {actual.value} (expected {spec.expected.value})"
    else:
        message = f"Port {spec.port}/{spec.protocol.value} is {actual.value} but expected {spec.expected.value}!"

    return TestResult(
        spec=spec,
        actual=actual,
        passed=passed,
        message=message,
        banner=banner,
        response_time_ms=response_time,
    )


# =============================================================================
# Discovery scan (find unexpected open ports)
# =============================================================================

def scan_port_range_tcp(host: str, ports: list[int], timeout: float = 1.5,
                        max_workers: int = 100,
                        progress_callback: Optional[callable] = None) -> list[ScanResult]:
    """Scan a range of TCP ports in parallel to find open ones."""
    open_ports = []
    completed = 0
    total = len(ports)

    def check_port(port: int) -> Optional[ScanResult]:
        state, banner, _ = test_tcp_port(host, port, timeout)
        if state == ActualState.OPEN:
            return ScanResult(port, Protocol.TCP, state, banner)
        return None

    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = {executor.submit(check_port, port): port for port in ports}
        for future in concurrent.futures.as_completed(futures):
            result = future.result()
            if result:
                open_ports.append(result)
            completed += 1
            if progress_callback:
                progress_callback(completed, total, len(open_ports))

    return sorted(open_ports, key=lambda x: x.port)


def get_discovery_ports(quick: bool = False) -> list[int]:
    """Get list of ports to scan for discovery."""
    if quick:
        # Quick scan: well-known (1-1023) + common high ports
        ports = set(range(1, 1024))

        # Add common service ports
        common_high_ports = [
            1080, 1433, 1521, 2049, 2375, 2376, 2377, 2379, 2380,
            3000, 3306, 3389, 4000, 4443, 4444, 5000, 5432, 5672,
            5900, 5901, 5902, 5903, 5904, 5905, 5939, 6000, 6379,
            6443, 6666, 6667, 7000, 7001, 8000, 8080, 8081, 8443,
            8888, 9000, 9090, 9092, 9200, 9300, 10000, 10250, 10255,
            11211, 11434, 15672, 21118, 27017,
            # RustDesk and VMware specific
            21119, 902, 912, 8222, 8333,
            # VS Code / code-server / IDE ports
            8889, 3001, 3030, 7080, 5678, 9229, 9222, 9230, 9003,
            2345, 5005, 4024, 2087, 5173, 5174, 4200, 4201, 8082,
            6006, 6007, 24678,
        ]
        ports.update(common_high_ports)

        return sorted(ports)
    else:
        # Full scan: all ports 1-65535 (default)
        return list(range(1, 65536))


# =============================================================================
# Main test runner
# =============================================================================

def run_specified_tests(host: str, port_specs: list[PortSpec],
                        description: str, timeout: float = 3.0) -> list[TestResult]:
    """Run tests for a list of port specifications."""
    results = []
    for spec in port_specs:
        result = test_port(host, spec, timeout)
        results.append(result)
    return results


def print_section(title: str) -> None:
    """Print a section header."""
    print()
    print("=" * 70)
    print(f"  {title}")
    print("=" * 70)


def print_result(result: TestResult, verbose: bool = True) -> None:
    """Print a single test result."""
    if result.passed:
        status = "\033[92m[PASS]\033[0m"
    elif result.spec.severity_if_wrong == Severity.WARNING:
        status = "\033[93m[WARN]\033[0m"
    else:
        status = "\033[91m[FAIL]\033[0m"

    print(f"{status} {result.spec.service}: {result.message}")

    if verbose:
        print(f"       Port: {result.spec.port}/{result.spec.protocol.value}")
        print(f"       Purpose: {result.spec.description}")
        if result.banner:
            print(f"       Banner: {result.banner}")
        if result.response_time_ms:
            print(f"       Response: {result.response_time_ms:.1f}ms")


def run_all_tests(target_ipv4: str, target_ipv6: Optional[str] = None,
                  quick: bool = False, verbose: bool = True) -> TestSummary:
    """Run all security tests and return summary."""
    start_time = time.strftime('%Y-%m-%d %H:%M:%S %Z')
    start_ts = time.time()

    summary = TestSummary(
        target_ipv4=target_ipv4,
        target_ipv6=target_ipv6,
        start_time=start_time,
        end_time="",
        duration_seconds=0,
    )

    print("=" * 70)
    print("COMPREHENSIVE REMOTE PORT SECURITY TESTER")
    print("=" * 70)
    print(f"Target IPv4: {target_ipv4}")
    if target_ipv6:
        print(f"Target IPv6: {target_ipv6}")
    print(f"Scan mode: {'QUICK (~1100 common ports)' if quick else 'FULL (1-65535)'}")
    print(f"Started: {start_time}")
    print("=" * 70)

    # -------------------------------------------------------------------------
    # Test 1: Services that MUST be open
    # -------------------------------------------------------------------------
    print_section("1. SERVICES THAT MUST BE ACCESSIBLE")
    print("Testing ports that should accept connections from the internet...")
    print()

    for result in run_specified_tests(target_ipv4, MUST_BE_OPEN, "must be open"):
        print_result(result, verbose)
        if result.passed:
            summary.passed.append(result)
        elif result.spec.severity_if_wrong == Severity.WARNING:
            summary.warnings.append(result)
        else:
            summary.critical_failures.append(result)

    # -------------------------------------------------------------------------
    # Test 2: VMware ports that MUST be blocked
    # -------------------------------------------------------------------------
    print_section("2. VMWARE PORTS THAT MUST BE BLOCKED")
    print("Testing VMware ports that should be blocked by iptables DROP rules...")
    print()

    for result in run_specified_tests(target_ipv4, MUST_BE_BLOCKED_VMWARE, "must be blocked"):
        print_result(result, verbose)
        if result.passed:
            summary.passed.append(result)
        elif result.spec.severity_if_wrong == Severity.WARNING:
            summary.warnings.append(result)
        else:
            summary.critical_failures.append(result)

    # -------------------------------------------------------------------------
    # Test 3: Localhost-only services that must NOT be exposed
    # -------------------------------------------------------------------------
    print_section("3. LOCALHOST-ONLY SERVICES (MUST NOT BE EXPOSED)")
    print("Testing services that should only be accessible from localhost...")
    print()

    for result in run_specified_tests(target_ipv4, MUST_NOT_BE_EXPOSED, "must not be exposed"):
        print_result(result, verbose)
        if result.passed:
            summary.passed.append(result)
        elif result.spec.severity_if_wrong == Severity.WARNING:
            summary.warnings.append(result)
        else:
            summary.critical_failures.append(result)

    # -------------------------------------------------------------------------
    # Test 4: VMware VNC ports
    # -------------------------------------------------------------------------
    print_section("4. VMWARE VNC PORTS (SHOULD NOT BE EXPOSED)")
    print("Testing VMware VNC ports (only used if VM VNC is explicitly enabled)...")
    print()

    vnc_results = run_specified_tests(target_ipv4, VMWARE_VNC_PORTS, "VMware VNC")
    vnc_failures = [r for r in vnc_results if not r.passed]
    vnc_passed = [r for r in vnc_results if r.passed]

    if vnc_failures:
        for result in vnc_failures:
            print_result(result, verbose)
            summary.critical_failures.append(result)
    else:
        print(f"\033[92m[PASS]\033[0m All {len(VMWARE_VNC_PORTS)} VMware VNC ports (5900-5909) are closed")

    summary.passed.extend(vnc_passed)

    # -------------------------------------------------------------------------
    # Test 5: VS Code / Code Server / IDE ports
    # -------------------------------------------------------------------------
    print_section("5. VS CODE / CODE SERVER / IDE PORTS")
    print("Testing IDE and development server ports (code-server, Jupyter, debuggers)...")
    print()

    vscode_results = run_specified_tests(target_ipv4, VSCODE_IDE_PORTS, "VS Code/IDE", timeout=2.0)
    vscode_failures = [r for r in vscode_results if not r.passed]
    vscode_passed = [r for r in vscode_results if r.passed]

    if vscode_failures:
        for result in vscode_failures:
            print_result(result, verbose)
            summary.critical_failures.append(result)
    else:
        print(f"\033[92m[PASS]\033[0m All {len(VSCODE_IDE_PORTS)} VS Code/IDE ports are closed")

    summary.passed.extend(vscode_passed)

    # -------------------------------------------------------------------------
    # Test 6: Common dangerous ports
    # -------------------------------------------------------------------------
    print_section("6. COMMON DANGEROUS PORTS")
    print("Testing ports commonly exploited or accidentally left open...")
    print()

    dangerous_results = run_specified_tests(target_ipv4, COMMON_DANGEROUS_PORTS, "dangerous ports", timeout=2.0)
    dangerous_failures = [r for r in dangerous_results if not r.passed]
    dangerous_passed = [r for r in dangerous_results if r.passed]

    if dangerous_failures:
        for result in dangerous_failures:
            print_result(result, verbose)
            if result.spec.severity_if_wrong == Severity.WARNING:
                summary.warnings.append(result)
            else:
                summary.critical_failures.append(result)
    else:
        print(f"\033[92m[PASS]\033[0m All {len(COMMON_DANGEROUS_PORTS)} common dangerous ports are closed")

    summary.passed.extend(dangerous_passed)

    # -------------------------------------------------------------------------
    # Test 7: Discovery scan for unexpected open ports
    # -------------------------------------------------------------------------
    print_section("7. DISCOVERY SCAN FOR UNEXPECTED OPEN PORTS")
    discovery_ports = get_discovery_ports(quick)
    print(f"Scanning {len(discovery_ports):,} TCP ports for unexpected open services...")
    print()

    # Get list of expected open ports
    expected_open = {22, 21118}  # SSH and RustDesk TCP

    # Progress callback for in-place updates
    last_percent = [-1]  # Use list to allow mutation in closure
    scan_start = time.time()

    def show_progress(completed: int, total: int, found: int) -> None:
        percent = (completed * 100) // total
        # Update every 1% to avoid excessive output
        if percent > last_percent[0]:
            last_percent[0] = percent
            elapsed = time.time() - scan_start
            # Estimate remaining time based on progress
            if completed > 0 and percent < 100:
                eta = (elapsed / completed) * (total - completed)
                eta_str = f"ETA {eta:.0f}s" if eta < 120 else f"ETA {eta/60:.1f}m"
            else:
                eta_str = ""
            print(f"\r  Progress: {percent:3d}% ({completed:,}/{total:,}) | Open: {found} | {eta_str}    ", end="", flush=True)

    open_ports = scan_port_range_tcp(target_ipv4, discovery_ports, timeout=1.5,
                                     progress_callback=show_progress)
    # Clear progress line and move to next line
    print("\r" + " " * 70 + "\r", end="")
    unexpected = [p for p in open_ports if p.port not in expected_open]

    if unexpected:
        print(f"\033[91m[FAIL]\033[0m Found {len(unexpected)} unexpected open TCP port(s):")
        for scan_result in unexpected:
            print(f"       Port {scan_result.port}: {scan_result.banner or 'no banner'}")
            summary.unexpected_open_ports.append(scan_result)
    else:
        expected_found = [p for p in open_ports if p.port in expected_open]
        print(f"\033[92m[PASS]\033[0m Only expected ports are open: {[p.port for p in expected_found]}")

    # -------------------------------------------------------------------------
    # Test 8: IPv6 tests (if provided)
    # -------------------------------------------------------------------------
    if target_ipv6:
        print_section("8. IPv6 SECURITY TESTS")
        print(f"Testing IPv6 address: {target_ipv6}")
        print()

        # Test critical ports on IPv6
        ipv6_specs = MUST_BE_BLOCKED_VMWARE + MUST_NOT_BE_EXPOSED + VSCODE_IDE_PORTS

        for result in run_specified_tests(target_ipv6, ipv6_specs, "IPv6"):
            # Prepend IPv6 to service name for clarity
            if not result.passed:
                print_result(result, verbose)
                if result.spec.severity_if_wrong == Severity.WARNING:
                    summary.ipv6_warnings.append(result)
                else:
                    summary.ipv6_critical_failures.append(result)

        ipv6_failures = len(summary.ipv6_critical_failures)
        ipv6_warnings = len(summary.ipv6_warnings)

        if ipv6_failures == 0 and ipv6_warnings == 0:
            print(f"\033[92m[PASS]\033[0m All IPv6 security checks passed")
        elif ipv6_failures == 0:
            print(f"\033[93m[WARN]\033[0m IPv6: {ipv6_warnings} warning(s)")
        else:
            print(f"\033[91m[FAIL]\033[0m IPv6: {ipv6_failures} critical failure(s)")

    # -------------------------------------------------------------------------
    # Summary
    # -------------------------------------------------------------------------
    end_time = time.strftime('%Y-%m-%d %H:%M:%S %Z')
    duration = time.time() - start_ts

    summary.end_time = end_time
    summary.duration_seconds = duration

    print_section("SUMMARY")

    total_critical = len(summary.critical_failures) + len(summary.ipv6_critical_failures)
    total_warnings = len(summary.warnings) + len(summary.ipv6_warnings)
    total_passed = len(summary.passed)
    total_unexpected = len(summary.unexpected_open_ports)

    print(f"Duration: {duration:.1f} seconds")
    print(f"Target: {target_ipv4}" + (f" / {target_ipv6}" if target_ipv6 else ""))
    print()
    print(f"Passed:              {total_passed}")
    print(f"Warnings:            {total_warnings}")
    print(f"Critical failures:   {total_critical}")
    print(f"Unexpected ports:    {total_unexpected}")
    print()

    if total_critical > 0 or total_unexpected > 0:
        print("\033[91m" + "!" * 70 + "\033[0m")
        print("\033[91m  SECURITY ISSUES DETECTED - IMMEDIATE ACTION REQUIRED\033[0m")
        print("\033[91m" + "!" * 70 + "\033[0m")
        print()

        if summary.critical_failures:
            print("Critical failures (IPv4):")
            for result in summary.critical_failures:
                print(f"  - {result.spec.service} on port {result.spec.port}: {result.actual.value}")

        if summary.ipv6_critical_failures:
            print("Critical failures (IPv6):")
            for result in summary.ipv6_critical_failures:
                print(f"  - {result.spec.service} on port {result.spec.port}: {result.actual.value}")

        if summary.unexpected_open_ports:
            print("Unexpected open ports:")
            for scan_result in summary.unexpected_open_ports:
                print(f"  - Port {scan_result.port}/TCP: {scan_result.banner or 'unknown service'}")

        print()
        print("Recommended actions:")
        print("  1. Run on the server: sudo python3 ./network_security/verify_network_security.py")
        print("  2. Apply VMware firewall: sudo python3 ./network_security/apply_vmware_firewall.py")
        print("  3. Check for misconfigured services binding to 0.0.0.0")

    elif total_warnings > 0:
        print("\033[93m" + "-" * 70 + "\033[0m")
        print("\033[93m  PASSED WITH WARNINGS\033[0m")
        print("\033[93m" + "-" * 70 + "\033[0m")
        print()
        print("Warnings (non-critical):")
        for result in summary.warnings + summary.ipv6_warnings:
            print(f"  - {result.spec.service}: {result.message}")
    else:
        print("\033[92m" + "=" * 70 + "\033[0m")
        print("\033[92m  ALL SECURITY CHECKS PASSED\033[0m")
        print("\033[92m" + "=" * 70 + "\033[0m")

    return summary


def main():
    parser = argparse.ArgumentParser(
        description="Comprehensive remote port security tester for DMZ-exposed personal server.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    python3 remote_port_tester.py --target YOUR_SERVER_IP
    python3 remote_port_tester.py --target YOUR_SERVER_IP --quick
    python3 remote_port_tester.py --target YOUR_SERVER_IP --ipv6 YOUR_IPV6_ADDR

By default, scans ALL 65535 TCP ports. Use --quick for faster ~1100 port scan.

This script tests from a remote location to verify:
  - Expected services (SSH, RustDesk) are accessible
  - VMware ports (902, 912, 8222, 8333) are blocked by firewall
  - Localhost-only services are not accidentally exposed
  - No unexpected ports are open on ANY port

Designed to catch security misconfigurations after system reinstall.
"""
    )

    parser.add_argument(
        "-t", "--target",
        type=str,
        required=True,
        help="Target IPv4 address to test"
    )

    parser.add_argument(
        "-6", "--ipv6",
        type=str,
        default=None,
        help="Target IPv6 address to test (optional)"
    )

    parser.add_argument(
        "--quick",
        action="store_true",
        default=False,
        help="Quick scan (~1100 common ports) instead of full scan (1-65535)"
    )

    parser.add_argument(
        "-q", "--quiet",
        action="store_true",
        default=False,
        help="Quiet mode - less verbose output"
    )

    args = parser.parse_args()

    # Validate IPv4 address
    try:
        socket.inet_aton(args.target)
    except socket.error:
        print(f"Error: Invalid IPv4 address: {args.target}", file=sys.stderr)
        sys.exit(1)

    # Validate IPv6 address if provided
    if args.ipv6:
        try:
            socket.inet_pton(socket.AF_INET6, args.ipv6)
        except socket.error:
            print(f"Error: Invalid IPv6 address: {args.ipv6}", file=sys.stderr)
            sys.exit(1)

    # Validate connectivity before running tests
    if not validate_connectivity(args.target, args.ipv6):
        sys.exit(3)  # Connectivity validation failed

    # Run tests
    summary = run_all_tests(
        target_ipv4=args.target,
        target_ipv6=args.ipv6,
        quick=args.quick,
        verbose=not args.quiet,
    )

    # Exit with appropriate code
    total_critical = len(summary.critical_failures) + len(summary.ipv6_critical_failures)
    total_unexpected = len(summary.unexpected_open_ports)
    total_warnings = len(summary.warnings) + len(summary.ipv6_warnings)

    if total_critical > 0 or total_unexpected > 0:
        sys.exit(2)  # Security issues
    elif total_warnings > 0:
        sys.exit(1)  # Warnings
    else:
        sys.exit(0)  # All good


if __name__ == "__main__":
    main()
