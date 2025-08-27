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

1. Update packages and install NVIDIA open driver (575):
   ```bash
   sudo apt update
   sudo apt install -y nvidia-driver-575-open nvidia-dkms-575-open
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

## 7. Switch the host to **Xorg** and (optionally) add a virtual display

By default both RustDesk and TeamViewer show black screen when the physical display is off in Wayland.\
To fix this buy an EDID DisplayPort emulator from Amazon.

## 8. Install Openssh server

`sudo apt install openssh-server`

Then turn on SSH connection from Ubuntu settings GUI app.

## 9. Install OpenWebUI

```sh
sudo docker run -d -p 127.0.0.1:3000:8080 --add-host=host.docker.internal:host-gateway -v open-webui:/app/backend/data --name open-webui --restart always ghcr.io/open-webui/open-webui:v0.6.25
```

## 10. Install Ollama

[install_ollama_user_service.sh](./install_ollama_user_service.sh)
