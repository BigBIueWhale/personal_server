#!/usr/bin/env python3
"""
Apply VMware port blocking rules with automatic rollback safety.

This script:
1. Verifies environment is exactly as expected (refuses to run if anything is off)
2. Checks if rules are already applied (refuses if so)
3. Backs up current iptables rules
4. Applies DROP rules for VMware ports (902, 912, 8222, 8333)
5. Waits 5 minutes for confirmation
6. If CTRL+C is pressed: commits changes permanently
7. If 5 minutes pass without CTRL+C: aggressively rolls back

Must be run as root (sudo).

Usage:
    sudo python3 apply_vmware_firewall.py
"""

import subprocess
import sys
import os
import signal
import time
from pathlib import Path
from dataclasses import dataclass


# =============================================================================
# Configuration
# =============================================================================

ROLLBACK_TIMEOUT_SECONDS = 300  # 5 minutes

# Rules to apply: (protocol, port, description)
VMWARE_BLOCK_RULES = [
    ("tcp", 902, "VMware Authentication Daemon"),
    ("udp", 902, "VMware Authentication Daemon (UDP)"),
    ("tcp", 912, "VMware Authorization Service"),
    ("tcp", 8222, "VMware Management Interface (HTTP)"),
    ("tcp", 8333, "VMware Management Interface (HTTPS)"),
]

BACKUP_DIR = Path.home() / "iptables-backups"
BACKUP_FILE_V4 = BACKUP_DIR / "iptables-before-vmware-block.rules"
BACKUP_FILE_V6 = BACKUP_DIR / "ip6tables-before-vmware-block.rules"

REQUIRED_COMMANDS = [
    "iptables", "ip6tables",
    "iptables-save", "ip6tables-save",
    "iptables-restore", "ip6tables-restore",
    "netfilter-persistent",
]


# =============================================================================
# State
# =============================================================================

class State:
    """Global state for signal handlers."""
    confirmed = False
    rules_applied = False
    backup_created = False


# =============================================================================
# Verification (strict - refuse on any anomaly)
# =============================================================================

def verify_root():
    """Verify script is running as root. Refuse if not."""
    if os.geteuid() != 0:
        print("REFUSED: This script must be run as root (sudo).")
        print("Usage: sudo python3 apply_vmware_firewall.py")
        sys.exit(1)
    print("[OK] Running as root")


def verify_commands_exist():
    """Verify all required commands exist. Refuse if any missing."""
    for cmd in REQUIRED_COMMANDS:
        result = subprocess.run(["which", cmd], capture_output=True)
        if result.returncode != 0:
            print(f"REFUSED: Required command '{cmd}' not found.")
            if cmd == "netfilter-persistent":
                print("Install with: sudo apt install iptables-persistent")
                print("  Note: You will be prompted 'Save current IPv4 rules?' and 'Save current IPv6 rules?'")
                print("  Answer YES to both (your INPUT chain should be empty, so this is safe).")
            sys.exit(1)
    print(f"[OK] All required commands available: {', '.join(REQUIRED_COMMANDS)}")


def verify_iptables_format():
    """
    Verify iptables -S INPUT output format is exactly as expected.
    Refuse if format is unexpected.
    """
    for cmd_name in ["iptables", "ip6tables"]:
        result = subprocess.run([cmd_name, "-S", "INPUT"], capture_output=True, text=True)
        if result.returncode != 0:
            print(f"REFUSED: '{cmd_name} -S INPUT' failed with code {result.returncode}")
            print(f"stderr: {result.stderr}")
            sys.exit(1)

        lines = result.stdout.strip().split('\n')
        if not lines:
            print(f"REFUSED: '{cmd_name} -S INPUT' returned empty output")
            sys.exit(1)

        # First line must be policy
        first_line = lines[0].strip()
        if not first_line.startswith("-P INPUT "):
            print(f"REFUSED: Expected first line to be policy (-P INPUT ...), got: {first_line!r}")
            sys.exit(1)

        policy = first_line.split()[-1]
        if policy not in ("ACCEPT", "DROP"):
            print(f"REFUSED: Unexpected INPUT policy: {policy!r}")
            sys.exit(1)

        # Verify each subsequent line is a valid rule format
        for line in lines[1:]:
            line = line.strip()
            if not line:
                continue
            if not line.startswith("-A INPUT "):
                print(f"REFUSED: Unexpected line format in {cmd_name} output: {line!r}")
                sys.exit(1)

    print("[OK] iptables/ip6tables output format verified")


def verify_input_chain_empty():
    """
    Verify INPUT chain has no rules (only policy).
    Refuse if there are existing rules.
    """
    for cmd_name in ["iptables", "ip6tables"]:
        result = subprocess.run([cmd_name, "-S", "INPUT"], capture_output=True, text=True)
        lines = [l.strip() for l in result.stdout.strip().split('\n') if l.strip()]

        # Should only have the policy line
        if len(lines) != 1:
            print(f"REFUSED: {cmd_name} INPUT chain is not empty.")
            print(f"Expected only policy line, but found {len(lines)} lines:")
            for line in lines:
                print(f"  {line}")
            print()
            print("If you have already applied VMware blocking rules, they are already in place.")
            print("If you want to re-apply, first remove existing rules with:")
            print(f"  sudo {cmd_name} -F INPUT")
            sys.exit(1)

    print("[OK] INPUT chains are empty (only default policy)")


def verify_policy_is_accept():
    """Verify INPUT chain policy is ACCEPT. Refuse if DROP."""
    for cmd_name in ["iptables", "ip6tables"]:
        result = subprocess.run([cmd_name, "-S", "INPUT"], capture_output=True, text=True)
        first_line = result.stdout.strip().split('\n')[0]
        policy = first_line.split()[-1]

        if policy != "ACCEPT":
            print(f"REFUSED: {cmd_name} INPUT policy is {policy}, expected ACCEPT.")
            print("This script is designed for systems with default ACCEPT policy.")
            sys.exit(1)

    print("[OK] INPUT chain policies are ACCEPT")


def verify_no_backup_exists():
    """Refuse if backup files already exist (indicates incomplete previous run)."""
    if BACKUP_FILE_V4.exists() or BACKUP_FILE_V6.exists():
        print("REFUSED: Backup files from previous run exist:")
        if BACKUP_FILE_V4.exists():
            print(f"  {BACKUP_FILE_V4}")
        if BACKUP_FILE_V6.exists():
            print(f"  {BACKUP_FILE_V6}")
        print()
        print("This indicates a previous run did not complete properly.")
        print("To proceed, either:")
        print("  1. Restore from backup: sudo iptables-restore < ~/iptables-backups/...")
        print("  2. Remove backup files manually if you're sure current state is correct")
        sys.exit(1)

    print("[OK] No stale backup files")


def run_all_verifications():
    """Run all verifications. Refuse if any fail."""
    print("=" * 60)
    print("VERIFICATION PHASE")
    print("=" * 60)
    print()

    verify_root()
    verify_commands_exist()
    verify_iptables_format()
    verify_input_chain_empty()
    verify_policy_is_accept()
    verify_no_backup_exists()

    print()
    print("All verifications passed.")


# =============================================================================
# Backup (careful)
# =============================================================================

def create_backup():
    """Create backup of current iptables rules."""
    print()
    print("=" * 60)
    print("BACKUP PHASE")
    print("=" * 60)
    print()

    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    print(f"Backup directory: {BACKUP_DIR}")

    # Backup IPv4
    result = subprocess.run(["iptables-save"], capture_output=True, text=True)
    if result.returncode != 0:
        print(f"REFUSED: iptables-save failed: {result.stderr}")
        sys.exit(1)
    BACKUP_FILE_V4.write_text(result.stdout)
    print(f"IPv4 backup: {BACKUP_FILE_V4}")

    # Backup IPv6
    result = subprocess.run(["ip6tables-save"], capture_output=True, text=True)
    if result.returncode != 0:
        print(f"REFUSED: ip6tables-save failed: {result.stderr}")
        sys.exit(1)
    BACKUP_FILE_V6.write_text(result.stdout)
    print(f"IPv6 backup: {BACKUP_FILE_V6}")

    State.backup_created = True
    print("Backup complete.")


# =============================================================================
# Apply rules (careful - refuse on any error)
# =============================================================================

def apply_rules():
    """Apply VMware port blocking rules. Refuse on any error."""
    print()
    print("=" * 60)
    print("APPLYING RULES")
    print("=" * 60)
    print()

    for protocol, port, description in VMWARE_BLOCK_RULES:
        # IPv4
        cmd = ["iptables", "-A", "INPUT", "-p", protocol, "--dport", str(port), "-j", "DROP"]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"FAILED: {' '.join(cmd)}")
            print(f"stderr: {result.stderr}")
            print("Initiating emergency rollback...")
            aggressive_rollback()
            sys.exit(1)
        print(f"[+] iptables  -A INPUT -p {protocol} --dport {port} -j DROP  # {description}")

        # IPv6
        cmd = ["ip6tables", "-A", "INPUT", "-p", protocol, "--dport", str(port), "-j", "DROP"]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"FAILED: {' '.join(cmd)}")
            print(f"stderr: {result.stderr}")
            print("Initiating emergency rollback...")
            aggressive_rollback()
            sys.exit(1)
        print(f"[+] ip6tables -A INPUT -p {protocol} --dport {port} -j DROP  # {description}")

    State.rules_applied = True
    print()
    print("All rules applied successfully.")


def show_current_rules():
    """Display current INPUT chain rules."""
    print()
    print("Current state:")
    print()

    print("IPv4 (iptables -S INPUT):")
    result = subprocess.run(["iptables", "-S", "INPUT"], capture_output=True, text=True)
    for line in result.stdout.strip().split('\n'):
        print(f"  {line}")

    print()
    print("IPv6 (ip6tables -S INPUT):")
    result = subprocess.run(["ip6tables", "-S", "INPUT"], capture_output=True, text=True)
    for line in result.stdout.strip().split('\n'):
        print(f"  {line}")


# =============================================================================
# Rollback (aggressive - try everything)
# =============================================================================

def aggressive_rollback():
    """
    Aggressively rollback to previous state.
    Try multiple approaches. Never give up.
    """
    print()
    print("!" * 60)
    print("! ROLLBACK IN PROGRESS - RESTORING PREVIOUS STATE")
    print("!" * 60)
    print()

    success_v4 = False
    success_v6 = False

    # Attempt 1: Restore from backup file
    print("Attempt 1: Restore from backup files...")

    if BACKUP_FILE_V4.exists():
        for attempt in range(3):
            try:
                with open(BACKUP_FILE_V4, 'r') as f:
                    result = subprocess.run(
                        ["iptables-restore"],
                        stdin=f,
                        capture_output=True,
                        text=True,
                        timeout=30
                    )
                    if result.returncode == 0:
                        print(f"  [OK] IPv4 restored from backup")
                        success_v4 = True
                        break
                    else:
                        print(f"  [RETRY {attempt+1}/3] iptables-restore failed: {result.stderr}")
            except Exception as e:
                print(f"  [RETRY {attempt+1}/3] Exception: {e}")
            time.sleep(1)
    else:
        print(f"  [WARN] IPv4 backup file not found: {BACKUP_FILE_V4}")

    if BACKUP_FILE_V6.exists():
        for attempt in range(3):
            try:
                with open(BACKUP_FILE_V6, 'r') as f:
                    result = subprocess.run(
                        ["ip6tables-restore"],
                        stdin=f,
                        capture_output=True,
                        text=True,
                        timeout=30
                    )
                    if result.returncode == 0:
                        print(f"  [OK] IPv6 restored from backup")
                        success_v6 = True
                        break
                    else:
                        print(f"  [RETRY {attempt+1}/3] ip6tables-restore failed: {result.stderr}")
            except Exception as e:
                print(f"  [RETRY {attempt+1}/3] Exception: {e}")
            time.sleep(1)
    else:
        print(f"  [WARN] IPv6 backup file not found: {BACKUP_FILE_V6}")

    # Attempt 2: If restore failed, try flushing INPUT chain
    if not success_v4:
        print()
        print("Attempt 2: Flush IPv4 INPUT chain...")
        for attempt in range(3):
            try:
                result = subprocess.run(
                    ["iptables", "-F", "INPUT"],
                    capture_output=True,
                    text=True,
                    timeout=30
                )
                if result.returncode == 0:
                    print(f"  [OK] IPv4 INPUT chain flushed")
                    success_v4 = True
                    break
                else:
                    print(f"  [RETRY {attempt+1}/3] iptables -F INPUT failed: {result.stderr}")
            except Exception as e:
                print(f"  [RETRY {attempt+1}/3] Exception: {e}")
            time.sleep(1)

    if not success_v6:
        print()
        print("Attempt 2: Flush IPv6 INPUT chain...")
        for attempt in range(3):
            try:
                result = subprocess.run(
                    ["ip6tables", "-F", "INPUT"],
                    capture_output=True,
                    text=True,
                    timeout=30
                )
                if result.returncode == 0:
                    print(f"  [OK] IPv6 INPUT chain flushed")
                    success_v6 = True
                    break
                else:
                    print(f"  [RETRY {attempt+1}/3] ip6tables -F INPUT failed: {result.stderr}")
            except Exception as e:
                print(f"  [RETRY {attempt+1}/3] Exception: {e}")
            time.sleep(1)

    # Attempt 3: Delete rules one by one
    if not success_v4 or not success_v6:
        print()
        print("Attempt 3: Delete rules individually...")
        v4_all_deleted = True
        v6_all_deleted = True
        for protocol, port, _ in reversed(VMWARE_BLOCK_RULES):
            if not success_v4:
                deleted = False
                for attempt in range(3):
                    result = subprocess.run(
                        ["iptables", "-D", "INPUT", "-p", protocol, "--dport", str(port), "-j", "DROP"],
                        capture_output=True, text=True
                    )
                    if result.returncode == 0:
                        print(f"  [OK] Deleted iptables rule for {protocol}/{port}")
                        deleted = True
                        break
                if not deleted:
                    v4_all_deleted = False
            if not success_v6:
                deleted = False
                for attempt in range(3):
                    result = subprocess.run(
                        ["ip6tables", "-D", "INPUT", "-p", protocol, "--dport", str(port), "-j", "DROP"],
                        capture_output=True, text=True
                    )
                    if result.returncode == 0:
                        print(f"  [OK] Deleted ip6tables rule for {protocol}/{port}")
                        deleted = True
                        break
                if not deleted:
                    v6_all_deleted = False
        if not success_v4 and v4_all_deleted:
            success_v4 = True
        if not success_v6 and v6_all_deleted:
            success_v6 = True

    # Verify rollback by checking INPUT chain
    print()
    print("Verifying rollback...")
    verify_failed = False
    for cmd_name in ["iptables", "ip6tables"]:
        result = subprocess.run([cmd_name, "-S", "INPUT"], capture_output=True, text=True)
        lines = [l.strip() for l in result.stdout.strip().split('\n') if l.strip()]
        # Check if any of our DROP rules are still present
        for line in lines:
            for protocol, port, _ in VMWARE_BLOCK_RULES:
                if f"-p {protocol}" in line and f"--dport {port}" in line and "-j DROP" in line:
                    print(f"  [WARN] Rule still present in {cmd_name}: {line}")
                    verify_failed = True
    if not verify_failed:
        print("  [OK] No VMware DROP rules found in INPUT chains")

    print()
    print("=" * 60)
    if success_v4 and success_v6 and not verify_failed:
        print("ROLLBACK COMPLETE")
    else:
        print("ROLLBACK PARTIALLY COMPLETE - MANUAL INTERVENTION MAY BE NEEDED")
        print()
        print("Try manually:")
        print("  sudo iptables -F INPUT")
        print("  sudo ip6tables -F INPUT")
    print("=" * 60)

    # Only clean up backup files if rollback was fully successful
    if success_v4 and success_v6 and not verify_failed:
        try:
            if BACKUP_FILE_V4.exists():
                BACKUP_FILE_V4.unlink()
            if BACKUP_FILE_V6.exists():
                BACKUP_FILE_V6.unlink()
        except:
            pass  # Best effort cleanup
    else:
        print()
        print("Backup files preserved for manual recovery:")
        if BACKUP_FILE_V4.exists():
            print(f"  {BACKUP_FILE_V4}")
        if BACKUP_FILE_V6.exists():
            print(f"  {BACKUP_FILE_V6}")


# =============================================================================
# Commit (save permanently)
# =============================================================================

def commit_rules():
    """Save rules permanently with netfilter-persistent."""
    print()
    print("=" * 60)
    print("COMMITTING CHANGES")
    print("=" * 60)
    print()

    result = subprocess.run(["netfilter-persistent", "save"], capture_output=True, text=True)
    if result.returncode != 0:
        print(f"WARNING: netfilter-persistent save failed: {result.stderr}")
        print("Rules are applied but may not persist after reboot.")
        print("Try manually: sudo netfilter-persistent save")
    else:
        print("Rules saved permanently. They will persist across reboots.")

    # Clean up backup files
    print()
    print("Cleaning up backup files...")
    try:
        if BACKUP_FILE_V4.exists():
            BACKUP_FILE_V4.unlink()
            print(f"  Removed: {BACKUP_FILE_V4}")
        if BACKUP_FILE_V6.exists():
            BACKUP_FILE_V6.unlink()
            print(f"  Removed: {BACKUP_FILE_V6}")
    except Exception as e:
        print(f"  Warning: Could not remove backup files: {e}")

    print()
    print("=" * 60)
    print("SUCCESS: VMware ports are now blocked permanently.")
    print("=" * 60)


# =============================================================================
# Signal handling
# =============================================================================

def handle_confirm_signal(signum, frame):
    """Handle CTRL+C (SIGINT) or SIGTERM - commit changes."""
    signal_name = "SIGINT (CTRL+C)" if signum == signal.SIGINT else "SIGTERM"
    print(f"\n\nReceived {signal_name}")
    State.confirmed = True


# =============================================================================
# Main
# =============================================================================

def main():
    print()
    print("=" * 60)
    print("VMware Port Blocking Script")
    print("with Automatic 5-Minute Rollback Safety")
    print("=" * 60)
    print()

    # Phase 1: Verify everything is exactly as expected
    run_all_verifications()

    # Phase 2: Create backup
    create_backup()

    # Phase 3: Apply rules
    apply_rules()
    show_current_rules()

    # Phase 4: Wait for confirmation
    signal.signal(signal.SIGINT, handle_confirm_signal)
    signal.signal(signal.SIGTERM, handle_confirm_signal)

    print()
    print("=" * 60)
    print("WAITING FOR CONFIRMATION")
    print("=" * 60)
    print()
    print("Firewall rules have been applied TEMPORARILY.")
    print()
    print(">>> TEST YOUR CONNECTION NOW <<<")
    print("Open a NEW SSH or RustDesk session to verify connectivity.")
    print()
    print(f"You have {ROLLBACK_TIMEOUT_SECONDS // 60} minutes to confirm.")
    print()
    print("  Press CTRL+C  -->  COMMIT changes permanently")
    print(f"  Wait {ROLLBACK_TIMEOUT_SECONDS // 60} min     -->  ROLLBACK automatically")
    print()

    start_time = time.time()
    try:
        while True:
            elapsed = time.time() - start_time
            remaining = ROLLBACK_TIMEOUT_SECONDS - elapsed

            if State.confirmed:
                commit_rules()
                return 0

            if remaining <= 0:
                print(f"\n\nTimeout reached ({ROLLBACK_TIMEOUT_SECONDS // 60} minutes).")
                print("No confirmation received.")
                aggressive_rollback()
                return 1

            mins, secs = divmod(int(remaining), 60)
            if int(remaining) % 30 == 0 or remaining < 10:
                print(f"  Time remaining: {mins:02d}:{secs:02d}  [CTRL+C to commit]")
            time.sleep(1)

    except Exception as e:
        print(f"\n\nUnexpected error: {e}")
        print("Initiating emergency rollback...")
        aggressive_rollback()
        return 1


if __name__ == "__main__":
    sys.exit(main())
