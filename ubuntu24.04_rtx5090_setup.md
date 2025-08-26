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
```sh
user@rtx5090:~/Desktop/cuda$ wget rustdesk.com/oss.yml -O compose.yml
--2025-08-26 22:52:47--  http://rustdesk.com/oss.yml
Resolving rustdesk.com (rustdesk.com)... 2001:19f0:4400:6ac5:5400:1ff:fe99:cb38, 45.76.181.120
Connecting to rustdesk.com (rustdesk.com)|2001:19f0:4400:6ac5:5400:1ff:fe99:cb38|:80... connected.
HTTP request sent, awaiting response... 301 Moved Permanently
Location: https://rustdesk.com/oss.yml [following]
--2025-08-26 22:52:47--  https://rustdesk.com/oss.yml
Connecting to rustdesk.com (rustdesk.com)|2001:19f0:4400:6ac5:5400:1ff:fe99:cb38|:443... connected.
HTTP request sent, awaiting response... 200 OK
Length: 402 [application/octet-stream]
Saving to: ‘compose.yml’

compose.yml                                   100%[=================================================================================================>]     402  --.-KB/s    in 0s      

2025-08-26 22:52:48 (389 MB/s) - ‘compose.yml’ saved [402/402]

user@rtx5090:~/Desktop/cuda$ sudo docker compose up -d
[sudo] password for user: 
[+] Running 5/5
 ✔ hbbs Pulled                                                                                                                                                                     4.9s 
   ✔ 9e455e83a929 Pull complete                                                                                                                                                    1.2s 
   ✔ cf1dc9594c7d Pull complete                                                                                                                                                    1.2s 
   ✔ 4f3b5a2b0508 Pull complete                                                                                                                                                    1.3s 
 ✔ hbbr Pulled                                                                                                                                                                     5.1s 
[+] Running 2/2
 ✔ Container hbbr  Started                                                                                                                                                         0.3s 
 ✔ Container hbbs  Started                                                                                                                                                         0.3s 
user@rtx5090:~/Desktop/cuda$ 
```
