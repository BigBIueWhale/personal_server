#!/usr/bin/env python3
"""
Network Security Verification Script for DMZ-Exposed Host

This script verifies that:
1. iptables rules are correctly configured to block VMware ports
2. No unexpected services are listening on external interfaces
3. Expected services are running and bound correctly

Must be run as root (sudo) to get full process information from ss.

Exit codes:
  0 = All checks passed
  1 = One or more checks failed
  2 = Script error (permissions, missing tools, etc.)
"""

import subprocess
import sys
import re
import os
from dataclasses import dataclass
from typing import Optional


# =============================================================================
# Configuration: Define expected and forbidden ports
# =============================================================================

# Ports that MUST be blocked by iptables (VMware Workstation Pro ports)
IPTABLES_MUST_BLOCK = {
    ("tcp", 902): "VMware Authentication Daemon",
    ("udp", 902): "VMware Authentication Daemon (UDP)",
    ("tcp", 912): "VMware Authorization Service",
    ("tcp", 8222): "VMware Management Interface (HTTP)",
    ("tcp", 8333): "VMware Management Interface (HTTPS)",
}

# Ports that should NOT be listening on 0.0.0.0 or :: (external interfaces)
# These are VMware ports that we don't block with iptables but should verify aren't listening
FORBIDDEN_EXTERNAL_PORTS = {
    ("tcp", 443): "VMware Workstation Server / Shared VMs (vmware-hostd)",
}

# Ports that ARE expected to listen on external interfaces (0.0.0.0 or ::)
EXPECTED_EXTERNAL_TCP_PORTS = {
    22: "OpenSSH Server (sshd)",
    21118: "RustDesk direct IP access",
}

EXPECTED_EXTERNAL_UDP_PORTS = {
    21119: "RustDesk signaling/relay",
    # Note: RustDesk also uses dynamic ephemeral UDP ports for P2P hole punching
    # These are in range 32768-60999 and are expected
}

# Ports expected on localhost only (informational, not checked for violations)
EXPECTED_LOCALHOST_PORTS = {
    3000: "OpenWebUI (docker-proxy)",
    11434: "Ollama (on Docker bridge 172.17.0.1)",
    5939: "TeamViewer daemon",
    631: "CUPS printing",
    53: "systemd-resolved DNS",
}

# Process names that indicate RustDesk (for identifying expected ephemeral UDP ports)
RUSTDESK_PROCESS_NAMES = {"rustdesk", "rustdesk-"}


# =============================================================================
# Data structures
# =============================================================================

@dataclass
class ListeningSocket:
    """Represents a listening socket from ss output."""
    protocol: str  # "tcp" or "udp"
    local_address: str  # e.g., "0.0.0.0" or "127.0.0.1" or "::"
    local_port: int
    process_name: Optional[str]
    pid: Optional[int]

    def is_localhost(self) -> bool:
        """Returns True if listening only on localhost (not accessible from network)."""
        # IPv4 localhost: 127.0.0.0/8
        if self.local_address.startswith("127."):
            return True
        # IPv6 localhost
        if self.local_address == "::1":
            return True
        return False

    def is_docker_bridge(self) -> bool:
        """Returns True if listening on Docker bridge network (not accessible from internet)."""
        # Docker default bridge networks
        if self.local_address.startswith("172.17."):
            return True
        if self.local_address.startswith("172.18."):
            return True
        # Docker can also use other 172.x.0.0/16 ranges, but we only whitelist known ones
        return False

    def is_external(self) -> bool:
        """
        Returns True if this socket is accessible from the external network (internet).

        For a DMZ-exposed host, ANYTHING that is not explicitly localhost or Docker bridge
        is potentially accessible from the internet. This includes:
        - 0.0.0.0 (all IPv4 interfaces)
        - :: (all IPv6 interfaces)
        - * (wildcard)
        - Any specific interface IP (e.g., 192.168.1.100, public IP, etc.)

        We use an allowlist approach: only known-safe addresses are NOT external.
        Everything else is treated as external to avoid missing exposed services.
        """
        if self.is_localhost():
            return False
        if self.is_docker_bridge():
            return False
        # Everything else is external - this is the safe/paranoid approach
        # This catches 0.0.0.0, ::, *, and any specific interface IPs
        return True


@dataclass
class CheckResult:
    """Result of a single check."""
    passed: bool
    message: str
    details: Optional[str] = None


# =============================================================================
# Utility functions
# =============================================================================

def run_command(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess:
    """Run a command and return the result."""
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=check,
        )
        return result
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"Command failed: {' '.join(cmd)}\nstderr: {e.stderr}")
    except FileNotFoundError:
        raise RuntimeError(f"Command not found: {cmd[0]}")


def check_root() -> None:
    """Verify script is running as root."""
    if os.geteuid() != 0:
        print("ERROR: This script must be run as root (sudo) to get full socket information.")
        print("Usage: sudo python3 verify_network_security.py")
        sys.exit(2)


def print_header(title: str) -> None:
    """Print a section header."""
    print()
    print("=" * 70)
    print(f"  {title}")
    print("=" * 70)


def print_result(result: CheckResult) -> None:
    """Print a check result with color coding."""
    status = "\033[92m[PASS]\033[0m" if result.passed else "\033[91m[FAIL]\033[0m"
    print(f"{status} {result.message}")
    if result.details:
        for line in result.details.strip().split("\n"):
            print(f"       {line}")


# =============================================================================
# Parsing functions
# =============================================================================

def parse_ss_output(output: str, protocol: str) -> list[ListeningSocket]:
    """Parse output from 'ss -tlnp' or 'ss -ulnp' into ListeningSocket objects."""
    sockets = []
    lines = output.strip().split("\n")

    for line in lines[1:]:  # Skip header
        if not line.strip():
            continue

        parts = line.split()
        if len(parts) < 4:
            continue

        # Parse local address:port (index 3 in ss output)
        # Format: State Recv-Q Send-Q Local-Address:Port Peer-Address:Port Process
        local_addr_port = parts[3]

        # Handle IPv6 addresses like [::]:22 or [::1]:631
        if local_addr_port.startswith("["):
            match = re.match(r'\[([^\]]+)\]:(\d+)', local_addr_port)
            if match:
                local_address = match.group(1)
                local_port = int(match.group(2))
            else:
                continue
        else:
            # IPv4 or wildcard like 0.0.0.0:22 or *:21118
            if ":" in local_addr_port:
                addr_part, port_part = local_addr_port.rsplit(":", 1)
                local_address = addr_part
                try:
                    local_port = int(port_part)
                except ValueError:
                    continue
            else:
                continue

        # Parse process info if available (requires root)
        process_name = None
        pid = None

        # Look for users:(("process",pid=123,...)) - search the entire line
        # The process info might be split across multiple parts due to spaces
        line_remainder = " ".join(parts[5:]) if len(parts) > 5 else ""
        full_search = line_remainder if line_remainder else line
        match = re.search(r'users:\(\("([^"]+)",pid=(\d+)', full_search)
        if match:
            process_name = match.group(1)
            pid = int(match.group(2))

        sockets.append(ListeningSocket(
            protocol=protocol,
            local_address=local_address,
            local_port=local_port,
            process_name=process_name,
            pid=pid,
        ))

    return sockets


def get_listening_sockets() -> list[ListeningSocket]:
    """Get all listening TCP and UDP sockets."""
    sockets = []

    # Get TCP sockets
    result = run_command(["ss", "-tlnp"])
    sockets.extend(parse_ss_output(result.stdout, "tcp"))

    # Get UDP sockets
    result = run_command(["ss", "-ulnp"])
    sockets.extend(parse_ss_output(result.stdout, "udp"))

    return sockets


# =============================================================================
# iptables checking functions
# =============================================================================

@dataclass
class IptablesRule:
    """Represents a single iptables rule from -S output."""
    rule_number: int  # 1-indexed position in chain
    protocol: str     # "tcp" or "udp"
    port: int         # destination port
    action: str       # "DROP", "REJECT", "ACCEPT", etc.
    raw_line: str     # original line for debugging


@dataclass
class IptablesChain:
    """Represents parsed iptables INPUT chain."""
    policy: str                    # "ACCEPT" or "DROP"
    rules: list[IptablesRule]      # rules in evaluation order


class IptablesParseError(Exception):
    """Raised when iptables output format is unexpected."""
    pass


def parse_iptables_s_output(output: str, command_name: str) -> IptablesChain:
    """
    Parse output from 'iptables -S INPUT' or 'ip6tables -S INPUT'.

    Uses logic-based parsing, not regex.
    Fails loudly if format is unexpected.

    Args:
        output: stdout from the command
        command_name: "iptables" or "ip6tables" for error messages

    Returns:
        IptablesChain with policy and list of rules

    Raises:
        IptablesParseError: if output format is unexpected
    """
    lines = output.strip().split('\n')
    if not lines:
        raise IptablesParseError(f"{command_name} -S INPUT returned empty output")

    policy = None
    rules = []
    rule_number = 0

    for line in lines:
        line = line.strip()
        if not line:
            continue

        parts = line.split()
        if len(parts) < 2:
            raise IptablesParseError(
                f"{command_name}: unexpected line format (too few parts): {line!r}"
            )

        # Parse policy line: "-P INPUT ACCEPT" or "-P INPUT DROP"
        if parts[0] == '-P':
            if len(parts) != 3:
                raise IptablesParseError(
                    f"{command_name}: unexpected policy line format: {line!r}"
                )
            if parts[1] != 'INPUT':
                raise IptablesParseError(
                    f"{command_name}: expected INPUT chain but got {parts[1]!r}: {line!r}"
                )
            if parts[2] not in ('ACCEPT', 'DROP'):
                raise IptablesParseError(
                    f"{command_name}: unexpected policy {parts[2]!r}: {line!r}"
                )
            policy = parts[2]
            continue

        # Parse rule line: "-A INPUT -p tcp -m tcp --dport 65432 -j DROP"
        if parts[0] == '-A':
            if len(parts) < 3:
                raise IptablesParseError(
                    f"{command_name}: unexpected rule line format: {line!r}"
                )
            if parts[1] != 'INPUT':
                # Rule for different chain, skip
                continue

            rule_number += 1

            # Extract protocol (-p tcp or -p udp)
            protocol = None
            try:
                p_idx = parts.index('-p')
                protocol = parts[p_idx + 1]
            except (ValueError, IndexError):
                # Rule without -p, might be for all protocols - skip for our purposes
                continue

            if protocol not in ('tcp', 'udp'):
                # We only care about tcp and udp for port blocking
                continue

            # Extract destination port (--dport NNNN)
            port = None
            try:
                dport_idx = parts.index('--dport')
                port = int(parts[dport_idx + 1])
            except (ValueError, IndexError):
                # Rule without --dport, skip for our purposes
                continue

            # Extract action (-j DROP, -j REJECT, -j ACCEPT, etc.)
            action = None
            try:
                j_idx = parts.index('-j')
                action = parts[j_idx + 1]
            except (ValueError, IndexError):
                raise IptablesParseError(
                    f"{command_name}: rule without -j action: {line!r}"
                )

            rules.append(IptablesRule(
                rule_number=rule_number,
                protocol=protocol,
                port=port,
                action=action,
                raw_line=line,
            ))
            continue

        # Unknown line type
        raise IptablesParseError(
            f"{command_name}: unexpected line type {parts[0]!r}: {line!r}"
        )

    if policy is None:
        raise IptablesParseError(
            f"{command_name}: no policy line (-P INPUT ...) found in output"
        )

    return IptablesChain(policy=policy, rules=rules)


def get_iptables_chain(ipv6: bool = False) -> IptablesChain:
    """
    Get and parse iptables INPUT chain.

    Uses 'iptables -S INPUT' format which is more machine-parseable than -L.
    """
    cmd_name = "ip6tables" if ipv6 else "iptables"
    cmd = [cmd_name, "-S", "INPUT"]
    result = run_command(cmd, check=False)

    if result.returncode != 0:
        raise IptablesParseError(
            f"{cmd_name} -S INPUT failed with code {result.returncode}: {result.stderr}"
        )

    return parse_iptables_s_output(result.stdout, cmd_name)


def check_port_is_blocked(chain: IptablesChain, protocol: str, port: int) -> tuple[bool, str]:
    """
    Check if a port is effectively blocked by the iptables chain.

    Rules are evaluated in order - first matching rule wins.

    Returns:
        (is_blocked, explanation)
    """
    for rule in chain.rules:
        if rule.protocol == protocol and rule.port == port:
            if rule.action in ('DROP', 'REJECT'):
                return True, f"Blocked by rule #{rule.rule_number} ({rule.action})"
            elif rule.action == 'ACCEPT':
                return False, f"ACCEPTED by rule #{rule.rule_number} BEFORE any DROP/REJECT"
            else:
                return False, f"Unknown action '{rule.action}' in rule #{rule.rule_number}"

    # No matching rule found - default policy applies
    if chain.policy == 'DROP':
        return True, "No explicit rule, but default policy is DROP"
    else:
        return False, "No DROP/REJECT rule found for this port"


def verify_iptables_rules(
    ipv4_chain: IptablesChain,
    ipv6_chain: IptablesChain,
) -> list[CheckResult]:
    """Verify all required iptables DROP rules are in place."""
    results = []

    for (protocol, port), description in IPTABLES_MUST_BLOCK.items():
        ipv4_blocked, ipv4_reason = check_port_is_blocked(ipv4_chain, protocol, port)
        ipv6_blocked, ipv6_reason = check_port_is_blocked(ipv6_chain, protocol, port)

        if ipv4_blocked and ipv6_blocked:
            results.append(CheckResult(
                passed=True,
                message=f"Port {port}/{protocol} is blocked (IPv4 and IPv6)",
                details=f"Service: {description}\nIPv4: {ipv4_reason}\nIPv6: {ipv6_reason}",
            ))
        else:
            problems = []
            if not ipv4_blocked:
                problems.append(f"IPv4: {ipv4_reason}")
            if not ipv6_blocked:
                problems.append(f"IPv6: {ipv6_reason}")

            results.append(CheckResult(
                passed=False,
                message=f"Port {port}/{protocol} is NOT fully blocked!",
                details=(
                    f"Service: {description}\n"
                    + "\n".join(problems) + "\n"
                    f"Fix with:\n"
                    f"  sudo iptables -A INPUT -p {protocol} --dport {port} -j DROP\n"
                    f"  sudo ip6tables -A INPUT -p {protocol} --dport {port} -j DROP"
                ),
            ))

    return results


# =============================================================================
# Listening port checking functions
# =============================================================================

def is_expected_rustdesk_ephemeral(socket: ListeningSocket) -> bool:
    """Check if this is an expected RustDesk ephemeral UDP port."""
    if socket.protocol != "udp":
        return False
    if not socket.is_external():
        return False
    if socket.local_port < 32768 or socket.local_port > 60999:
        return False  # Not in ephemeral range
    if socket.process_name and any(name in socket.process_name.lower() for name in RUSTDESK_PROCESS_NAMES):
        return True
    return False


def verify_no_forbidden_ports(sockets: list[ListeningSocket]) -> list[CheckResult]:
    """Verify no forbidden ports are listening on external interfaces."""
    results = []

    for (protocol, port), description in FORBIDDEN_EXTERNAL_PORTS.items():
        matching = [s for s in sockets if s.protocol == protocol and s.local_port == port and s.is_external()]

        if matching:
            socket = matching[0]
            results.append(CheckResult(
                passed=False,
                message=f"FORBIDDEN: Port {port}/{protocol} is listening on external interface!",
                details=(
                    f"Service: {description}\n"
                    f"Process: {socket.process_name or 'unknown'} (PID: {socket.pid or 'unknown'})\n"
                    f"Address: {socket.local_address}:{socket.local_port}\n"
                    f"This port should NOT be listening. Investigate and disable the service."
                ),
            ))
        else:
            results.append(CheckResult(
                passed=True,
                message=f"Port {port}/{protocol} is not listening externally (good)",
                details=f"Service that could use this: {description}",
            ))

    return results


def verify_no_unexpected_external_ports(
    sockets: list[ListeningSocket],
    ipv4_chain: Optional[IptablesChain] = None,
    ipv6_chain: Optional[IptablesChain] = None,
) -> list[CheckResult]:
    """Verify no unexpected ports are listening on external interfaces."""
    results = []
    unexpected = []
    rustdesk_ephemeral_ports = []
    vmware_blocked_ports = []  # VMware ports that are listening but blocked by iptables

    for socket in sockets:
        if not socket.is_external():
            continue

        # Check if this is an expected port
        if socket.protocol == "tcp":
            if socket.local_port in EXPECTED_EXTERNAL_TCP_PORTS:
                continue
        elif socket.protocol == "udp":
            if socket.local_port in EXPECTED_EXTERNAL_UDP_PORTS:
                continue
            # Check for RustDesk ephemeral ports
            if is_expected_rustdesk_ephemeral(socket):
                rustdesk_ephemeral_ports.append(socket)
                continue

        # Check if this is a VMware port that should be blocked by iptables
        if (socket.protocol, socket.local_port) in IPTABLES_MUST_BLOCK:
            # Cross-reference with actual iptables rules to verify it's blocked
            if ipv4_chain is not None and ipv6_chain is not None:
                ipv4_blocked, _ = check_port_is_blocked(ipv4_chain, socket.protocol, socket.local_port)
                ipv6_blocked, _ = check_port_is_blocked(ipv6_chain, socket.protocol, socket.local_port)
                if ipv4_blocked and ipv6_blocked:
                    vmware_blocked_ports.append(socket)
                    continue
            # If iptables chains not available or port not blocked, treat as unexpected
            unexpected.append(socket)
            continue

        # Check if this is a forbidden port
        if (socket.protocol, socket.local_port) in FORBIDDEN_EXTERNAL_PORTS:
            continue  # Will be reported by verify_no_forbidden_ports

        # This is truly unexpected
        unexpected.append(socket)

    # Report RustDesk ephemeral ports (show process verification for transparency)
    for socket in rustdesk_ephemeral_ports:
        results.append(CheckResult(
            passed=True,
            message=f"RustDesk ephemeral UDP port {socket.local_port} verified by process name",
            details=(
                f"Process: {socket.process_name} (PID: {socket.pid or 'unknown'})\n"
                f"Address: {socket.local_address}\n"
                f"Purpose: P2P hole punching (dynamic port in range 32768-60999)"
            ),
        ))

    # Report VMware ports that are listening but blocked by iptables (this is the expected secure state)
    if vmware_blocked_ports:
        for socket in vmware_blocked_ports:
            description = IPTABLES_MUST_BLOCK.get((socket.protocol, socket.local_port), "VMware service")
            results.append(CheckResult(
                passed=True,
                message=f"VMware port {socket.local_port}/{socket.protocol} listening but blocked by iptables",
                details=(
                    f"Service: {description}\n"
                    f"Process: {socket.process_name or 'unknown'} (PID: {socket.pid or 'unknown'})\n"
                    f"Address: {socket.local_address}\n"
                    f"Status: Secure (iptables DROP rules prevent external access)"
                ),
            ))

    if unexpected:
        for socket in unexpected:
            results.append(CheckResult(
                passed=False,
                message=f"UNEXPECTED: Port {socket.local_port}/{socket.protocol} listening on {socket.local_address}",
                details=(
                    f"Process: {socket.process_name or 'unknown'} (PID: {socket.pid or 'unknown'})\n"
                    f"This port was not in the expected list. Investigate whether this is:\n"
                    f"  1. A new legitimate service that should be added to expected list\n"
                    f"  2. An unwanted service that should be disabled or blocked"
                ),
            ))
    elif not vmware_blocked_ports:
        results.append(CheckResult(
            passed=True,
            message="No unexpected ports found listening on external interfaces",
        ))

    return results


def verify_expected_services(sockets: list[ListeningSocket]) -> list[CheckResult]:
    """Verify expected services are running and listening correctly."""
    results = []

    # Check expected TCP ports
    for port, description in EXPECTED_EXTERNAL_TCP_PORTS.items():
        matching = [s for s in sockets if s.protocol == "tcp" and s.local_port == port and s.is_external()]
        if matching:
            socket = matching[0]
            results.append(CheckResult(
                passed=True,
                message=f"Expected service running: {description} on port {port}/tcp",
                details=f"Process: {socket.process_name or 'unknown'} (PID: {socket.pid or 'unknown'})",
            ))
        else:
            results.append(CheckResult(
                passed=False,
                message=f"Expected service NOT running: {description} on port {port}/tcp",
                details="This service should be running. Check if the service is started.",
            ))

    # Check expected UDP ports
    for port, description in EXPECTED_EXTERNAL_UDP_PORTS.items():
        matching = [s for s in sockets if s.protocol == "udp" and s.local_port == port and s.is_external()]
        if matching:
            socket = matching[0]
            results.append(CheckResult(
                passed=True,
                message=f"Expected service running: {description} on port {port}/udp",
                details=f"Process: {socket.process_name or 'unknown'} (PID: {socket.pid or 'unknown'})",
            ))
        else:
            # UDP services might not always be listening, so this is a warning not a failure
            results.append(CheckResult(
                passed=True,  # Don't fail on this
                message=f"Note: {description} on port {port}/udp not currently listening",
                details="This may be normal if RustDesk is not actively connected.",
            ))

    return results


# =============================================================================
# Main function
# =============================================================================

def main() -> int:
    """Run all verification checks and report results."""
    print()
    print("Network Security Verification Script")
    print("For DMZ-exposed host with VMware Workstation Pro 17.6.4")
    print()

    # Check we're running as root
    check_root()

    all_passed = True

    # Collect all listening sockets
    print("Gathering socket information...")
    try:
        sockets = get_listening_sockets()
    except RuntimeError as e:
        print(f"ERROR: {e}")
        return 2

    print(f"Found {len(sockets)} listening sockets.\n")

    # Parse iptables chains once for use by multiple verification functions
    ipv4_chain: Optional[IptablesChain] = None
    ipv6_chain: Optional[IptablesChain] = None
    iptables_parse_failed = False

    print("Parsing iptables rules...")
    try:
        ipv4_chain = get_iptables_chain(ipv6=False)
    except IptablesParseError as e:
        print(f"\033[91m[FATAL]\033[0m Failed to parse iptables rules: {e}")
        iptables_parse_failed = True
        all_passed = False

    try:
        ipv6_chain = get_iptables_chain(ipv6=True)
    except IptablesParseError as e:
        print(f"\033[91m[FATAL]\033[0m Failed to parse ip6tables rules: {e}")
        iptables_parse_failed = True
        all_passed = False

    if not iptables_parse_failed:
        print("iptables rules parsed successfully.\n")

    # Section 1: Verify iptables rules
    print_header("1. iptables Rules Verification")
    print("Checking that VMware ports are blocked by iptables...")
    print()

    if iptables_parse_failed:
        print("\033[91m[SKIP]\033[0m Cannot verify iptables rules due to parsing failure above.")
    else:
        results = verify_iptables_rules(ipv4_chain, ipv6_chain)
        for result in results:
            print_result(result)
            if not result.passed:
                all_passed = False

    # Section 2: Verify forbidden ports
    print_header("2. Forbidden Ports Check")
    print("Checking that no forbidden services are listening externally...")
    print()

    results = verify_no_forbidden_ports(sockets)
    for result in results:
        print_result(result)
        if not result.passed:
            all_passed = False

    # Section 3: Verify no unexpected ports
    print_header("3. Unexpected Ports Check")
    print("Checking for any unexpected services on external interfaces...")
    print()

    results = verify_no_unexpected_external_ports(sockets, ipv4_chain, ipv6_chain)
    for result in results:
        print_result(result)
        if not result.passed:
            all_passed = False

    # Section 4: Verify expected services
    print_header("4. Expected Services Check")
    print("Verifying expected services are running...")
    print()

    results = verify_expected_services(sockets)
    for result in results:
        print_result(result)
        if not result.passed:
            all_passed = False

    # Summary
    print_header("SUMMARY")
    if all_passed:
        print("\033[92m✓ All security checks passed.\033[0m")
        print()
        return 0
    else:
        print("\033[91m✗ One or more security checks failed!\033[0m")
        print()
        print("Please review the failures above and take corrective action.")
        print("After fixing issues, run this script again to verify.")
        print()
        return 1


if __name__ == "__main__":
    sys.exit(main())
