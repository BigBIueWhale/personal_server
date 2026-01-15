#!/usr/bin/env python3
"""
Remote Port Connectivity Tester

This script tests network connectivity to a personal server from a remote location.
It verifies that:
  - Expected services (SSH, RustDesk) are accessible
  - VMware ports are properly blocked by firewall rules

Designed to run on Ubuntu 24.04 (or any Linux with Python 3.8+).

Usage:
    python3 remote_port_tester.py [--target IP_ADDRESS]

Example:
    python3 remote_port_tester.py --target 149.106.155.35
"""

import argparse
import socket
import sys
import time
from dataclasses import dataclass
from enum import Enum
from typing import Optional


class Protocol(Enum):
    TCP = "TCP"
    UDP = "UDP"


class ExpectedResult(Enum):
    OPEN = "OPEN"
    BLOCKED = "BLOCKED"


class ActualResult(Enum):
    OPEN = "OPEN"           # Connection succeeded or got response
    CLOSED = "CLOSED"       # Connection refused (RST) or ICMP unreachable
    FILTERED = "FILTERED"   # Timeout - packet dropped (firewall DROP rule)
    UNKNOWN = "UNKNOWN"     # Could not determine


@dataclass
class PortTest:
    port: int
    protocol: Protocol
    service: str
    expected: ExpectedResult
    description: str


# Define all ports to test based on the server's network security configuration
PORTS_TO_TEST = [
    # === Services that SHOULD be accessible ===
    PortTest(
        port=22,
        protocol=Protocol.TCP,
        service="OpenSSH",
        expected=ExpectedResult.OPEN,
        description="SSH server for remote administration"
    ),
    PortTest(
        port=21118,
        protocol=Protocol.TCP,
        service="RustDesk",
        expected=ExpectedResult.OPEN,
        description="RustDesk direct IP access port"
    ),
    PortTest(
        port=21119,
        protocol=Protocol.UDP,
        service="RustDesk",
        expected=ExpectedResult.OPEN,
        description="RustDesk signaling/relay port"
    ),

    # === VMware ports that SHOULD be BLOCKED ===
    PortTest(
        port=902,
        protocol=Protocol.TCP,
        service="VMware Auth Daemon",
        expected=ExpectedResult.BLOCKED,
        description="VMware Authentication Daemon (VNC/SOAP) - SECURITY RISK if exposed"
    ),
    PortTest(
        port=902,
        protocol=Protocol.UDP,
        service="VMware Auth Daemon",
        expected=ExpectedResult.BLOCKED,
        description="VMware console heartbeat/screen data"
    ),
    PortTest(
        port=912,
        protocol=Protocol.TCP,
        service="VMware authd",
        expected=ExpectedResult.BLOCKED,
        description="VMware Authorization Service (secondary port)"
    ),
    PortTest(
        port=8222,
        protocol=Protocol.TCP,
        service="VMware hostd",
        expected=ExpectedResult.BLOCKED,
        description="VMware Management Interface (HTTP - plaintext!)"
    ),
    PortTest(
        port=8333,
        protocol=Protocol.TCP,
        service="VMware hostd",
        expected=ExpectedResult.BLOCKED,
        description="VMware Management Interface (HTTPS)"
    ),
]


def test_tcp_port(host: str, port: int, timeout: float = 5.0) -> tuple[ActualResult, Optional[str]]:
    """
    Test TCP connectivity to a host:port.

    Returns:
        tuple of (ActualResult, banner_or_error_message)
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)

    try:
        sock.connect((host, port))

        # Try to receive a banner (some services send data immediately)
        banner = None
        try:
            sock.settimeout(2.0)  # Short timeout for banner
            data = sock.recv(1024)
            if data:
                # Decode banner, handling binary data gracefully
                try:
                    banner = data.decode('utf-8', errors='replace').strip()[:100]
                except Exception:
                    banner = f"[binary data: {len(data)} bytes]"
        except socket.timeout:
            pass  # No banner sent, that's OK
        except Exception:
            pass

        sock.close()
        return ActualResult.OPEN, banner

    except socket.timeout:
        return ActualResult.FILTERED, "Connection timed out (firewall DROP rule likely active)"

    except ConnectionRefusedError:
        return ActualResult.CLOSED, "Connection refused (RST) - port closed or service not running"

    except OSError as e:
        if e.errno == 113:  # EHOSTUNREACH - No route to host
            return ActualResult.FILTERED, f"No route to host"
        elif e.errno == 101:  # ENETUNREACH - Network unreachable
            return ActualResult.FILTERED, f"Network unreachable"
        elif e.errno == 111:  # ECONNREFUSED
            return ActualResult.CLOSED, "Connection refused"
        else:
            return ActualResult.UNKNOWN, f"OS error: {e}"

    except Exception as e:
        return ActualResult.UNKNOWN, f"Error: {e}"

    finally:
        try:
            sock.close()
        except Exception:
            pass


def test_udp_port(host: str, port: int, timeout: float = 5.0) -> tuple[ActualResult, Optional[str]]:
    """
    Test UDP connectivity to a host:port.

    UDP is connectionless, so we send a probe packet and check for response.

    Results interpretation:
        - Response received -> OPEN (service responded)
        - ICMP unreachable -> CLOSED (port not listening)
        - Timeout -> FILTERED or OPEN (can't distinguish without app-layer response)

    Note: For the VMware blocked ports, we expect FILTERED (DROP rule = no response).
          For RustDesk UDP, we might get FILTERED too since it may not respond to
          arbitrary probes, but the port is actually open.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)

    try:
        # Send a small probe packet
        # For RustDesk, we could send a proper protocol message, but a simple probe works
        probe_data = b'\x00' * 8  # 8 null bytes as a generic probe

        sock.sendto(probe_data, (host, port))

        try:
            # Wait for response
            data, addr = sock.recvfrom(1024)
            if data:
                try:
                    response = data.decode('utf-8', errors='replace')[:50]
                except Exception:
                    response = f"[binary: {len(data)} bytes]"
                return ActualResult.OPEN, f"Got response: {response}"
            else:
                return ActualResult.OPEN, "Empty response received"

        except socket.timeout:
            # No response - could be filtered OR open but not responding to our probe
            return ActualResult.FILTERED, "No response (DROP rule or service ignores probe)"

        except ConnectionRefusedError:
            # ICMP port unreachable received
            return ActualResult.CLOSED, "ICMP Port Unreachable - port is closed"

        except OSError as e:
            if e.errno == 111:  # ECONNREFUSED - ICMP unreachable
                return ActualResult.CLOSED, "ICMP Port Unreachable"
            else:
                return ActualResult.UNKNOWN, f"OS error: {e}"

    except Exception as e:
        return ActualResult.UNKNOWN, f"Error: {e}"

    finally:
        try:
            sock.close()
        except Exception:
            pass


def run_tests(target_ip: str, verbose: bool = True) -> tuple[int, int, int]:
    """
    Run all port connectivity tests.

    Returns:
        tuple of (passed_count, failed_count, warning_count)
    """
    print("=" * 70)
    print("REMOTE PORT CONNECTIVITY TESTER")
    print("=" * 70)
    print(f"Target: {target_ip}")
    print(f"Test time: {time.strftime('%Y-%m-%d %H:%M:%S %Z')}")
    print("=" * 70)
    print()

    passed = 0
    failed = 0
    warnings = 0

    # Group tests by expected result for clearer output
    accessible_tests = [t for t in PORTS_TO_TEST if t.expected == ExpectedResult.OPEN]
    blocked_tests = [t for t in PORTS_TO_TEST if t.expected == ExpectedResult.BLOCKED]

    # Test accessible ports first
    print("-" * 70)
    print("TESTING PORTS THAT SHOULD BE ACCESSIBLE")
    print("-" * 70)

    for test in accessible_tests:
        print(f"\n[{test.protocol.value}] Port {test.port} ({test.service})")
        print(f"    Purpose: {test.description}")

        if test.protocol == Protocol.TCP:
            result, message = test_tcp_port(target_ip, test.port)
        else:
            result, message = test_udp_port(target_ip, test.port)

        if result == ActualResult.OPEN:
            status = "[PASS]"
            color_start = "\033[92m"  # Green
            passed += 1
            if message:
                print(f"    Banner: {message}")
        elif result == ActualResult.FILTERED:
            # For UDP, filtered might still mean open (service just doesn't respond to probe)
            if test.protocol == Protocol.UDP:
                status = "[WARN]"
                color_start = "\033[93m"  # Yellow
                warnings += 1
                print(f"    Note: UDP services may not respond to probes even when open")
            else:
                status = "[FAIL]"
                color_start = "\033[91m"  # Red
                failed += 1
        else:
            status = "[FAIL]"
            color_start = "\033[91m"  # Red
            failed += 1

        color_end = "\033[0m"
        print(f"    Result: {color_start}{result.value}{color_end} {status}")
        if message and result != ActualResult.OPEN:
            print(f"    Detail: {message}")

    # Test blocked ports
    print()
    print("-" * 70)
    print("TESTING VMWARE PORTS THAT SHOULD BE BLOCKED")
    print("-" * 70)

    for test in blocked_tests:
        print(f"\n[{test.protocol.value}] Port {test.port} ({test.service})")
        print(f"    Risk: {test.description}")

        if test.protocol == Protocol.TCP:
            result, message = test_tcp_port(target_ip, test.port)
        else:
            result, message = test_udp_port(target_ip, test.port)

        # For blocked ports: FILTERED or CLOSED is good, OPEN is bad
        if result in (ActualResult.FILTERED, ActualResult.CLOSED):
            status = "[PASS]"
            color_start = "\033[92m"  # Green
            passed += 1
        elif result == ActualResult.OPEN:
            status = "[FAIL] *** SECURITY RISK ***"
            color_start = "\033[91m"  # Red
            failed += 1
            if message:
                print(f"    WARNING: Service banner: {message}")
        else:
            status = "[WARN]"
            color_start = "\033[93m"  # Yellow
            warnings += 1

        color_end = "\033[0m"
        print(f"    Result: {color_start}{result.value}{color_end} {status}")
        if message and result not in (ActualResult.OPEN,):
            print(f"    Detail: {message}")

    # Summary
    print()
    print("=" * 70)
    print("SUMMARY")
    print("=" * 70)

    total = passed + failed + warnings

    if failed == 0 and warnings == 0:
        print("\033[92m" + "ALL TESTS PASSED" + "\033[0m")
    elif failed == 0:
        print("\033[93m" + f"PASSED WITH WARNINGS: {warnings} warning(s)" + "\033[0m")
    else:
        print("\033[91m" + f"SECURITY ISSUES DETECTED: {failed} failure(s)" + "\033[0m")

    print(f"\nPassed:   {passed}/{total}")
    print(f"Failed:   {failed}/{total}")
    print(f"Warnings: {warnings}/{total}")

    if failed > 0:
        print("\n" + "\033[91m" + "=" * 70 + "\033[0m")
        print("\033[91m" + "ACTION REQUIRED: Some VMware ports are exposed to the internet!" + "\033[0m")
        print("\033[91m" + "Run on the server:" + "\033[0m")
        print("    sudo python3 ./network_security/apply_vmware_firewall.py")
        print("\033[91m" + "=" * 70 + "\033[0m")

    return passed, failed, warnings


def main():
    parser = argparse.ArgumentParser(
        description="Test network connectivity to a personal server from a remote location.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    python3 remote_port_tester.py --target 149.106.155.35
    python3 remote_port_tester.py -t 203.0.113.10

This script tests:
  - Ports that SHOULD be accessible: SSH (22), RustDesk (21118/TCP, 21119/UDP)
  - VMware ports that SHOULD be BLOCKED: 902, 912, 8222, 8333

Expected results:
  - Accessible ports should return OPEN
  - Blocked ports should return FILTERED (DROP rule) or CLOSED
  - If blocked ports return OPEN, that's a SECURITY RISK!
"""
    )

    parser.add_argument(
        "-t", "--target",
        type=str,
        default="149.106.155.35",
        help="Target IP address to test (default: 149.106.155.35)"
    )

    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        default=True,
        help="Verbose output (default: True)"
    )

    args = parser.parse_args()

    # Validate IP address format
    try:
        socket.inet_aton(args.target)
    except socket.error:
        print(f"Error: Invalid IP address: {args.target}", file=sys.stderr)
        sys.exit(1)

    # Run tests
    passed, failed, warnings = run_tests(args.target, args.verbose)

    # Exit with appropriate code
    if failed > 0:
        sys.exit(2)  # Security issues detected
    elif warnings > 0:
        sys.exit(1)  # Warnings present
    else:
        sys.exit(0)  # All good


if __name__ == "__main__":
    main()
