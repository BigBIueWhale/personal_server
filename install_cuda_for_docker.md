# Install Docker GPU Support

You’re **good to go** (Driver **580.65.06**, CUDA **13.0**). The only thing missing is the **NVIDIA Container Toolkit** for Docker—hence the `could not select device driver "" with capabilities: [[gpu]]` error. Do this **exactly**, then ComfyUI (Qwen templates) will run on **localhost only**.

## Enable GPU in Docker (one time)

```bash
# 1) Install NVIDIA Container Toolkit (Ubuntu 24.04)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit

# 2) Wire Docker to the NVIDIA runtime
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

(These are the official NVIDIA steps; `nvidia-ctk` edits Docker’s config so `--gpus all` works.) ([NVIDIA Docs][1])

**Test it:**

```bash
sudo docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi
```

You should see your **RTX 5090** listed in the container. (Your driver supports CUDA **12.8** containers; image maintainer for ComfyUI also calls out “**driver ≥ 570** + **ubuntu24\_cuda12.8** for RTX 50xx”.) ([GitHub][2])
