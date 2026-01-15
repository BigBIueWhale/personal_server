# Network Security Posture (DMZ-Exposed Host)

This server operates behind a consumer router with **full DMZ mode enabled**, meaning the router forwards **all incoming connections on all ports and all protocols** (TCP, UDP, ICMP, etc.) directly to this machine's public IPv4 address. This is an intentional configuration choice to support services like RustDesk remote desktop and OpenSSH Server without tedious per-port forwarding rules.

Given this level of exposure to the public internet, it is absolutely critical to understand exactly which services are listening on external network interfaces (`0.0.0.0` or `::`) and ensure nothing unexpected is exposed.

---

## 1. Auditing Open Ports

Run these commands periodically to verify the network exposure of this host:

```bash
# TCP ports listening on all interfaces (requires sudo for process names)
sudo ss -tlnp

# UDP ports listening on all interfaces (requires sudo for process names)
sudo ss -ulnp

# List processes that commonly open network ports
ps aux | grep -E 'vmware|vmnet|rustdesk|ollama|sshd|docker|teamviewer' | grep -v grep
```

Or use the automated verification script included in this directory:

```bash
sudo python3 ./verify_network_security.py
```

To verify security from an **external perspective** (e.g., from a laptop in another city), use the remote port tester which scans all 65,535 TCP ports:

```bash
# Run from a DIFFERENT machine, not the server itself
python3 remote_port_tester.py --target YOUR_SERVER_IP

# Optional: include IPv6 testing
python3 remote_port_tester.py --target YOUR_SERVER_IP --ipv6 YOUR_SERVER_IPV6
```

A full scan takes approximately **10-15 minutes** depending on network latency. Use `--quick` for a faster ~1,100 port scan (~30 seconds).

---

## 2. Ports Intentionally Exposed to the Internet

These ports are **by design** exposed to the public internet and are required for the server to function as intended:

| Port | Protocol | Process | Purpose |
|------|----------|---------|---------|
| **22** | TCP | `sshd` (OpenSSH Server) | Secure Shell access for remote administration from any device including a Samsung Galaxy S25 smartphone running Termius, a MacBook Pro running Terminal, or a Windows 11 PC running PuTTY. Authentication is via SSH key pairs, not passwords. |
| **21118** | TCP | `rustdesk` | RustDesk direct IP access port. The RustDesk Client application (installed via `.deb` package from [rustdesk.com](https://rustdesk.com)) acts as both client and server simultaneously. This port allows incoming remote desktop connections without relying on RustDesk's public relay infrastructure. |
| **21119** | UDP | `rustdesk` | RustDesk signaling/relay port for WebSocket-based communication. |
| **Dynamic UDP** | UDP | `rustdesk` | RustDesk uses dynamically allocated ephemeral UDP ports for peer-to-peer (P2P) hole punching. The specific port number changes on each connection attempt (e.g., port 38642 in one session, port 41023 in another). This is expected and correct behavior—see Section 4 for why this matters. |

---

## 3. Services Bound to Localhost Only (Not Exposed)

These services listen exclusively on the loopback interface (`127.0.0.1`) or the Docker bridge network (`172.17.0.1`), meaning they are **completely inaccessible from the internet**:

| Port | Interface | Process | Purpose |
|------|-----------|---------|---------|
| **3000** | 127.0.0.1 | `docker-proxy` → OpenWebUI | OpenWebUI v0.6.25 web interface for interacting with local LLMs. Accessible only via `localhost:3000` or through an SSH tunnel. |
| **11434** | 172.17.0.1 | `ollama` | Ollama LLM inference API server. Bound specifically to the Docker bridge interface so the OpenWebUI container can communicate with it via `host.docker.internal`, while remaining inaccessible from the public internet. |
| **5939** | 127.0.0.1 | `teamviewerd` | TeamViewer daemon. TeamViewer establishes outbound connections to TeamViewer GmbH's relay infrastructure; no inbound port exposure is required or desired. |
| **631** | 127.0.0.1 | `cupsd` | CUPS (Common UNIX Printing System) daemon. Local printing services only. |
| **53** | 127.0.0.53 | `systemd-resolved` | Local DNS resolver stub for system DNS resolution. |

---

## 4. Why UFW (Uncomplicated Firewall) Must NOT Be Used

**Critical:** Do not enable UFW, firewalld, or any blanket firewall that indiscriminately blocks incoming UDP traffic on this server.

RustDesk's peer-to-peer connection mechanism relies on **UDP hole punching**, a NAT traversal technique that requires the ability to receive unsolicited incoming UDP packets on dynamically allocated ephemeral ports. After analyzing the [RustDesk source code on GitHub](https://github.com/rustdesk/rustdesk), specifically the file `src/lan.rs`, I confirmed that RustDesk binds UDP sockets to `0.0.0.0:0`, which instructs the Linux kernel to assign a random available port from the ephemeral port range (typically 32768-60999).

If you enable UFW with default deny policies:
- RustDesk P2P connections will fail during the hole-punching phase
- Connections will fall back to relay servers, which are slower and may be unreliable
- Direct IP access functionality may cease working entirely
- You would need to allow the entire ephemeral UDP port range, which defeats the purpose of the firewall

**The correct approach** for this DMZ-exposed server is to use **targeted iptables rules** that block only specific known-problematic ports (such as those opened by VMware Workstation Pro) while allowing all other traffic. See Section 5 below.

---

## 5. VMware Workstation Pro 17.x — Blocking Unwanted Network Exposure

Installing **VMware® Workstation 17 Pro version 17.6.4 (build-24832109)**, downloaded from [Broadcom's official support portal](https://support.broadcom.com), introduces a significant security concern: VMware's services automatically listen on network ports bound to all interfaces (`0.0.0.0` and `::`), exposing them to the public internet on a DMZ host.

### 5.1 The Problem: VMware Authentication Daemon on Port 902

Immediately after installing VMware Workstation Pro 17.6.4 on Ubuntu 24.04 LTS, the VMware Authentication Daemon (`vmware-authdlauncher`) begins listening on **TCP port 902** on all network interfaces—even before you launch the VMware GUI or create any virtual machines:

```bash
# Verify VMware's authentication daemon is listening
sudo ss -tlnp | grep 902
```

Output on this server:
```
LISTEN  0  5  0.0.0.0:902  0.0.0.0:*  users:(("vmware-authdlau",pid=409234,fd=11))
LISTEN  0  5     [::]:902     [::]:*  users:(("vmware-authdlau",pid=409234,fd=10))
```

Connecting to this port reveals the service banner:
```bash
nc -v 127.0.0.1 902
# Output: 220 VMware Authentication Daemon Version 1.10: SSL Required, ServerDaemonProtocol:SOAP, MKSDisplayProtocol:VNC , VMXARGS supported, NFCSSL supported
```

This daemon provides remote console access to virtual machines using VNC over SOAP protocol. It is the backend for VMware's "Connect to Remote Server" feature. On a DMZ-exposed server, this port is accessible to anyone on the internet.

### 5.2 Known Security Vulnerabilities in VMware Authentication Services

The VMware Authentication Daemon and related VMware services have documented security vulnerabilities:

| CVE | CVSS | Severity | Description |
|-----|------|----------|-------------|
| **CVE-2025-41236** | 9.3 | Critical | Integer overflow in VMXNET3 virtual network adapter allowing VM escape and host code execution. Fixed in 17.6.4. |
| **CVE-2025-41237** | 9.3 | Critical | Integer underflow in VMCI (Virtual Machine Communication Interface) leading to out-of-bounds write. Fixed in 17.6.4. |
| **CVE-2025-22224** | 9.3 | Critical | TOCTOU vulnerability leading to out-of-bounds write. **Actively exploited in the wild** per VMware advisory VMSA-2025-0004. |
| **CVE-2022-22972** | Critical | Critical | Authentication bypass via HTTP Host header manipulation in VMware management interfaces. |
| **CVE-2009-4811** | High | High | Format string vulnerability in VMware Authentication Daemon causing denial of service. |

Additionally, security tools specifically target port 902:
- [Nmap includes `vmauthd-brute`](https://nmap.org/nsedoc/scripts/vmauthd-brute.html) — a brute-force password auditing script for the VMware Authentication Daemon
- [Metasploit Framework includes `auxiliary/scanner/vmware/vmauthd_login`](https://www.rapid7.com/db/modules/auxiliary/scanner/vmware/vmauthd_login/) — a credential scanning module

### 5.3 Complete List of VMware Workstation Pro Network Ports

Based on extensive research of VMware documentation, community forums, and the [Arch Linux Wiki](https://wiki.archlinux.org/title/VMware), VMware Workstation Pro can potentially listen on the following ports:

| Port | Protocol | Service | Description | Action |
|------|----------|---------|-------------|--------|
| **902** | TCP | `vmware-authdlauncher` | VMware Authentication Daemon. Handles remote console connections using VNC/SOAP. | **BLOCK with iptables** |
| **902** | UDP | `vmware-authdlauncher` | Used for VM console heartbeat and screen data in some configurations. | **BLOCK with iptables** |
| **443** | TCP | `vmware-hostd` | VMware Workstation Server / Shared VMs feature. Feature was [removed in Workstation 16.2.0](https://knowledge.broadcom.com/external/article/327436). | Verify not listening (should not be) |
| **912** | TCP | `vmware-authd` | Secondary VMware Authorization Service port, primarily used on Windows hosts. | **BLOCK with iptables** |
| **8222** | TCP | `vmware-hostd` | VMware Management Interface over unencrypted HTTP. Credentials transmitted in plaintext. | **BLOCK with iptables** |
| **8333** | TCP | `vmware-hostd` | VMware Management Interface over HTTPS. Web-based VM management console. | **BLOCK with iptables** |

**Note regarding VNC ports (5900-5964):** These ports are only used if you explicitly configure a virtual machine as a VNC server via the VM's `.vmx` configuration file. This is a per-VM opt-in setting, not a system-wide service. If you enable VNC on any VM, you should add firewall rules for those specific ports as well.

### 5.4 Understanding the Existing iptables State

Before modifying iptables, it is essential to understand the current state. Ubuntu 24.04 LTS uses **nftables as the backend** for iptables (version 1.8.10 with nf_tables), which provides atomic rule application—if a command fails, no partial changes are made.

Running `sudo iptables-save` on this server reveals that **Docker has already established iptables infrastructure** across multiple tables:

| Table | Chains | Purpose |
|-------|--------|---------|
| `raw` | PREROUTING | Protects Docker containers from external access. Contains DROP rules for traffic destined to container IPs (172.17.0.0/16) arriving from non-docker interfaces. Also blocks external access to localhost-bound ports like 3000 (OpenWebUI). |
| `filter` | DOCKER, DOCKER-ISOLATION-STAGE-1/2, DOCKER-USER, DOCKER-FORWARD | Container isolation and traffic control. The FORWARD chain (not INPUT) handles inter-container and container-to-host communication. |
| `nat` | DOCKER, PREROUTING, POSTROUTING | Port mapping (DNAT) and masquerading (SNAT) for container networking. Maps localhost:3000 to the OpenWebUI container at 172.17.0.2:8080. |

**Critical observation:** The **INPUT chain is empty** with a default policy of ACCEPT. This is where our VMware-blocking rules will go. Docker's rules operate in the FORWARD chain (for container traffic routing), so our INPUT chain modifications will not interfere with Docker's networking.

```bash
# View current INPUT chain (should be empty)
sudo iptables -L INPUT -n --line-numbers

# View full iptables state including Docker rules
sudo iptables-save
```

### 5.5 The Solution: Block VMware Ports with Automatic Rollback

Since UFW cannot be used (it would break RustDesk's P2P functionality), we use **surgical iptables rules** to block only VMware's problematic ports while allowing all other traffic through.

Use the included Python script which provides **automatic 5-minute rollback safety** for remote administration:

```bash
sudo python3 ./apply_vmware_firewall.py
```

The script:

1. **Verifies environment** — Refuses to run if anything is unexpected (wrong iptables format, rules already applied, missing commands, etc.)
2. **Creates backup** — Saves current iptables state before making changes
3. **Applies DROP rules** — Blocks ports 902 (TCP/UDP), 912, 8222, 8333 on both IPv4 and IPv6
4. **Waits 5 minutes for confirmation** — Displays countdown timer
5. **On CTRL+C** — Commits changes permanently with `netfilter-persistent save`
6. **On timeout** — Aggressively rolls back to previous state (tries multiple recovery methods)

This is safe for remote administration: if the rules break your connection, wait 5 minutes and access will be restored automatically.

### 5.6 Verification: Confirm the Firewall Rules Are Active

After applying the iptables rules, run the verification script:

```bash
sudo python3 ./verify_network_security.py
```

Or manually verify:

```bash
# List IPv4 INPUT rules mentioning the blocked ports
sudo iptables -L INPUT -n --line-numbers | grep -E '902|912|8222|8333'

# List IPv6 INPUT rules
sudo ip6tables -L INPUT -n --line-numbers | grep -E '902|912|8222|8333'

# Verify port 443 is NOT listening (Shared VMs feature should be disabled)
sudo ss -tlnp | grep ':443 ' || echo "Port 443 not listening (good)"

# Attempt to connect to port 902 (should timeout due to DROP rule)
nc -v -w 3 127.0.0.1 902
# Expected: Connection timed out

# Verify rules persist after reboot
sudo reboot
# After reboot:
sudo iptables -L INPUT -n | grep 902
```

From an external perspective (e.g., scanning from another machine or using an online port scanner), ports 902, 912, 8222, and 8333 will appear as filtered or closed.

### 5.7 Why Not Disable vmware-authdlauncher Entirely?

You might wonder why we don't simply disable the `vmware-authdlauncher` service instead of blocking its port at the firewall level. According to [VMware's official documentation](https://knowledge.broadcom.com/external/article?legacyId=1007131):

> "vmware-authd is the VMware Authorization Service used in place of an Administrator account to start and access the guest virtual machines. **Disabling this service will render the VMs unable to start.**"

The authentication daemon is architecturally required for VMware Workstation Pro to function. Blocking the port at the firewall level is the correct solution: the service continues to operate for local VM management, but remote network access is prevented.

### 5.8 Other VMware Processes (Not Network-Exposed)

For completeness, these VMware processes run on this server but do **not** listen on external network interfaces:

| Process | Purpose |
|---------|---------|
| `vmware-usbarbitrator` | Manages USB device passthrough to virtual machines |
| `vmnet-bridge` | Bridges VM network traffic to physical network (vmnet0) |
| `vmnet-netifup` | Creates virtual network interfaces (vmnet1, vmnet8) |
| `vmnet-dhcpd` | Provides DHCP services to VMs on host-only and NAT networks |
| `vmnet-natd` | Provides NAT services for VMs on the NAT network (vmnet8) |
| `vmware` | The VMware Workstation Pro GUI application |
| `vmware-tray` | System tray indicator showing VM power state |

These processes communicate only with virtual machines and the local system; they do not accept incoming connections from external networks.
