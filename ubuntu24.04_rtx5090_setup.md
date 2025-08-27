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

```sh
user@rtx5090:~/Downloads/ollama-linux-amd64_v0.11.7/bin$ ./install_ollama_user_service.sh
Created symlink /home/user/.config/systemd/user/default.target.wants/ollama.service → /home/user/.config/systemd/user/ollama.service.

✔ Installed user service pointing at: /home/user/Downloads/ollama-linux-amd64_v0.11.7/bin/ollama
• Edit env here: /home/user/.config/ollama/env (then: systemctl --user restart ollama)
• Manage with:   systemctl --user status|restart|stop ollama

● ollama.service - Ollama (user) – local LLM server
     Loaded: loaded (/home/user/.config/systemd/user/ollama.service; enabled; preset: enabled)
     Active: active (running) since Wed 2025-08-27 21:08:12 IDT; 15ms ago
   Main PID: 608677 (ollama)
      Tasks: 1 (limit: 76002)
     Memory: 3.5M (peak: 3.5M)
        CPU: 2ms
     CGroup: /user.slice/user-1000.slice/user@1000.service/app.slice/ollama.service
             └─608677 /home/user/.local/opt/ollama/ollama serve

Aug 27 21:08:12 rtx5090 systemd[1816]: Started ollama.service - Ollama (user) – local LLM server.
Aug 27 21:08:12 rtx5090 ollama[608677]: time=2025-08-27T21:08:12.864+03:00 level=INFO source=routes.go:1331 msg="server config" env="map[CUDA_VISIBLE_DEVICES: GPU_DEVICE_ORDINAL: HIP_VISIBLE_DEVICES: HSA_OVERRIDE_GFX_VERSION: HTTPS_PROXY: HTTP_PROXY: NO_PROXY: OLLAMA_CONTEXT_LENGTH:4096 OLLAMA_DEBUG:INFO OLLAMA_FLASH_ATTENTION:false OLLAMA_GPU_OVERHEAD:0 OLLAMA_HOST:http://127.0.0.1:11434 OLLAMA_INTEL_GPU:false OLLAMA_KEEP_ALIVE:5m0s OLLAMA_KV_CACHE_TYPE: OLLAMA_LLM_LIBRARY: OLLAMA_LOAD_TIMEOUT:5m0s OLLAMA_MAX_LOADED_MODELS:0 OLLAMA_MAX_QUEUE:512 OLLAMA_MODELS:/home/user/.ollama/models OLLAMA_MULTIUSER_CACHE:false OLLAMA_NEW_ENGINE:false OLLAMA_NEW_ESTIMATES:false OLLAMA_NOHISTORY:false OLLAMA_NOPRUNE:false OLLAMA_NUM_PARALLEL:1 OLLAMA_ORIGINS:[http://localhost https://localhost http://localhost:* https://localhost:* http://127.0.0.1 https://127.0.0.1 http://127.0.0.1:* https://127.0.0.1:* http://0.0.0.0 https://0.0.0.0 http://0.0.0.0:* https://0.0.0.0:* app://* file://* tauri://* vscode-webview://* vscode-file://*] OLLAMA_SCHED_SPREAD:false ROCR_VISIBLE_DEVICES: http_proxy: https_proxy: no_proxy:]"
Aug 27 21:08:12 rtx5090 ollama[608677]: time=2025-08-27T21:08:12.864+03:00 level=INFO source=images.go:477 msg="total blobs: 15"
Aug 27 21:08:12 rtx5090 ollama[608677]: time=2025-08-27T21:08:12.865+03:00 level=INFO source=images.go:484 msg="total unused blobs removed: 0"
Aug 27 21:08:12 rtx5090 ollama[608677]: time=2025-08-27T21:08:12.865+03:00 level=INFO source=routes.go:1384 msg="Listening on 127.0.0.1:11434 (version 0.11.7)"
Aug 27 21:08:12 rtx5090 ollama[608677]: time=2025-08-27T21:08:12.865+03:00 level=INFO source=gpu.go:217 msg="looking for compatible GPUs"
user@rtx5090:~/Downloads/ollama-linux-amd64_v0.11.7/bin$
```
