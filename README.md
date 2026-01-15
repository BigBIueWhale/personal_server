# Ubuntu 24.04 LTS + RTX 5090 Setup Guide (Working Steps)

These are the steps to get **NVIDIA RTX 5090** working with CUDA on **Ubuntu 24.04 LTS**.

---

## 1. BIOS/UEFI Settings

1. **Disable Secure Boot**  
   - In BIOS/UEFI → `Boot` or `Security` → **Secure Boot = Disabled**.

2. **Disable Fast Boot** (optional).  
3. **Enable Auto Boot after Power Loss** (optional).

---

## 2. NVIDIA Driver Installation

1. Update packages and install NVIDIA open driver (580):
   ```bash
   sudo apt update
   sudo apt install -y nvidia-driver-580-open nvidia-dkms-580-open
   sudo reboot
   ```

2. Verify driver:
   ```bash
   nvidia-smi
   ```
   You should see the RTX 5090.

---

## 3. CUDA Toolkit Installation (13.0)

1. Add NVIDIA CUDA repo and install CUDA 13.0:
   ```bash
   wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
   sudo dpkg -i cuda-keyring_1.1-1_all.deb
   sudo apt update
   sudo apt install -y cuda-toolkit-13-0
   ```

2. Add CUDA to your environment:
   ```bash
   echo 'export PATH=/usr/local/cuda/bin:$PATH' >> ~/.bashrc
   echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' >> ~/.bashrc
   source ~/.bashrc
   ```

3. Verify CUDA:
   ```bash
   nvcc -V
   ```

---

## 4. Test CUDA

1. Install and build sample programs:
   ```bash
   sudo apt install -y nvidia-cuda-samples
   cd /usr/share/doc/nvidia-cuda-toolkit/examples/Samples/1_Utilities/deviceQuery
   make SMS=90
   ~/cuda_example/deviceQuery
   ```

2. Expected output: `Result = PASS`.

---

✅ At this point, the RTX 5090 works correctly on Ubuntu 24.04 LTS with CUDA 13.0 support.

## 5. Install Docker

https://erwansistandi.medium.com/install-docker-in-ubuntu-server-24-04-lts-bcfef5025c1a

## 6. Install RustDesk
Just the GUI client, and turn on direct access. No docker image, just the GUI which is a server by default.

## 7. Wayland Virtual Display Issue

By default both RustDesk and TeamViewer show black screen when the physical display is off in Wayland.\
To fix this buy an EDID DisplayPort emulator from Amazon.

Switching to Xorg doesn't solve the problem because Xorg uses up a bunch of VRAM, whereas Wayland is nice and uses the Intel iGPU for most things.

Wayland has another issue- unattended remote desktop access is purposefully inhibited "for security reasons". I created a project that provides a patch to disable that terrible Wayland "security" feature https://github.com/BigBIueWhale/ubuntu_patch_unattended_access. I've applied that security patch, and not my unattended access works perfectly.\
I hedge my bets by having both RustDesk and TeamViewer on the same machine.

## 8. Install Openssh server

`sudo apt install openssh-server`

Then turn on SSH connection from Ubuntu settings GUI app.

## 9. Install OpenWebUI

```sh
sudo docker run -d -p 127.0.0.1:3000:8080 --add-host=host.docker.internal:host-gateway -v open-webui:/app/backend/data --name open-webui --restart always ghcr.io/open-webui/open-webui:v0.6.25
```

## 10. Install Ollama

We specifically install OpenWebUI in a way that it can only access `host.docker.internal` and doesn't have direct access to the host network (such as 127.0.0.1).\
Therefore, we need to setup Ollama to listen on the `docker0` network interface.

My install script gives important environment variables for Ollama to use. Such as `OLLAMA_FLASH_ATTENTION` and `OLLAMA_HOST`.

[install_ollama_user_service.sh](./install_ollama_user_service.sh)

```sh
user@rtx5090:~/Downloads/ollama-linux-amd64_v0.11.7/bin$ ./install_ollama_user_service.sh

✔ Installed/updated user service pointing at: /home/user/Downloads/ollama-linux-amd64_v0.11.7/bin/ollama
• Pushed env to: /home/user/.config/ollama/env (OLLAMA_HOST set to 172.17.0.1:11434)
• Manage with:   systemctl --user status|restart|stop ollama

● ollama.service - Ollama (user) – local LLM server
     Loaded: loaded (/home/user/.config/systemd/user/ollama.service; enabled; preset: enabled)
     Active: active (running) since Fri 2025-08-29 11:45:38 IDT; 3ms ago
   Main PID: 901534 (ollama)
      Tasks: 1 (limit: 76002)
     Memory: 3.7M (peak: 3.7M)
        CPU: 2ms
     CGroup: /user.slice/user-1000.slice/user@1000.service/app.slice/ollama.service
             └─901534 /home/user/.local/opt/ollama/ollama serve

Aug 29 11:45:38 rtx5090 systemd[1843]: Started ollama.service - Ollama (user) – local LLM server.
user@rtx5090:~/Downloads/ollama-linux-amd64_v0.11.7/bin$
```

```sh
user@rtx5090:~/Downloads/ollama-linux-amd64_v0.11.7/bin$ OLLAMA_HOST=172.17.0.1:11434 ./ollama list
NAME            ID              SIZE     MODIFIED     
gemma3:27b      a418f5838eaf    17 GB    19 hours ago    
gpt-oss:120b    f7f8e2f8f4e0    65 GB    24 hours ago    
qwen3:32b       030ee887880f    20 GB    24 hours ago    
user@rtx5090:~/Downloads/ollama-linux-amd64_v0.11.7/bin$
```

Optionally, view logs from Ollama:
```sh
journalctl --user -u ollama.service -f
```

## 11. Free VRAM

Rustdesk tends to steal VRAM for use with its "hardware codec".\
Uncheck "hardware codec" usage in RustDesk settings to free the 500+ MB of VRAM that RustDesk uses during a remote connection.

# 12. Disable Avahi Server

Avahi = the Linux/Unix **mDNS/DNS-SD (“Bonjour/Zeroconf”)** service. It advertises and discovers things on your **local LAN** via multicast UDP 5353, e.g.:

* auto-discover network printers (AirPrint), scanners
* “.local” hostnames (e.g., `mypc.local`)
* file shares/SMB/AFP/NFS discovery in desktop environments
* media/cast/discovery for some apps

It’s **not** useful across the public internet and just adds attack surface/noise on a DMZ host.

## Permanently disable it (safe on a server)

```bash
# stop now
sudo systemctl stop avahi-daemon avahi-daemon.socket
sudo systemctl stop avahi-daemon avahi-daemon.service avahi-daemon.socket

# prevent starting at boot or via socket activation
sudo systemctl disable avahi-daemon avahi-daemon.service avahi-daemon.socket
sudo systemctl mask avahi-daemon avahi-daemon.socket

# verify nothing is listening on 5353 anymore
sudo ss -uapn | grep -E '(:|\.)(5353)\b' || echo "5353 closed"
systemctl is-enabled avahi-daemon; systemctl status avahi-daemon --no-pager
```

# 13. Install CUDA support for docker
See [installation guide](./install_cuda_for_docker.md).

# 14. Network Security (DMZ-Exposed Host)

This server runs with full DMZ mode enabled on the router, exposing all ports to the public internet. See **[Network Security Guide](./network_security/README.md)** for details on why UFW cannot be used and how VMware ports are blocked.

```bash
# Verify network security posture
sudo python3 ./network_security/verify_network_security.py

# Block VMware ports (902, 912, 8222, 8333) with 5-minute auto-rollback safety
# Press CTRL+C to commit changes, or wait 5 minutes to auto-rollback
sudo python3 ./network_security/apply_vmware_firewall.py
```

# 15. Fix VMware Workstation Copy/Paste (Wayland Host)

VMware Workstation Pro 17.x has broken clipboard sync on Wayland — copying from host to guest doesn't work due to a Mutter bug in Wayland→XWayland clipboard synchronization.

See **[VMware Host-Guest Integration](./vmware/README.md)** for solutions including clipboard sync and shared folder mounting.
