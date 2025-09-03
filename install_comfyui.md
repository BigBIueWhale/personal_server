# Install ComfyUI

You’re **good to go** (Driver **580.65.06**, CUDA **13.0**). The only thing missing is the **NVIDIA Container Toolkit** for Docker—hence the `could not select device driver "" with capabilities: [[gpu]]` error. Do this **exactly**, then ComfyUI (Qwen templates) will run on **localhost only**.

## A) Enable GPU in Docker (one time)

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

---

## B) (Optional but smart) Pre-fetch Qwen models so the GUI is ready

```bash
mkdir -p ~/comfy/run \
         ~/comfy/basedir/models/diffusion_models \
         ~/comfy/basedir/models/text_encoders \
         ~/comfy/basedir/models/vae

# Qwen Image (T2I) – fp8
wget -c https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/diffusion_models/qwen_image_fp8_e4m3fn.safetensors \
     -O ~/comfy/basedir/models/diffusion_models/qwen_image_fp8_e4m3fn.safetensors

# Qwen Image Edit (edit/inpaint) – fp8
wget -c https://huggingface.co/Comfy-Org/Qwen-Image-Edit_ComfyUI/resolve/main/split_files/diffusion_models/qwen_image_edit_fp8_e4m3fn.safetensors \
     -O ~/comfy/basedir/models/diffusion_models/qwen_image_edit_fp8_e4m3fn.safetensors

# Shared text encoder + VAE
wget -c https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors \
     -O ~/comfy/basedir/models/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors
wget -c https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors \
     -O ~/comfy/basedir/models/vae/qwen_image_vae.safetensors
```

(These are the **first-party Comfy** Qwen bundles; placements match Comfy’s Qwen pages.) ([Comfy Anonymous][3], [Hugging Face][4])

---

## C) Run ComfyUI (Docker, GPU, **127.0.0.1 only**)

```bash
sudo docker run -d --name comfyui \
  --gpus all --runtime nvidia \
  -e WANTED_UID=$(id -u) -e WANTED_GID=$(id -g) \
  -e BASE_DIRECTORY=/basedir -e SECURITY_LEVEL=normal \
  -v ~/comfy/run:/comfy/mnt \
  -v ~/comfy/basedir:/basedir \
  -p 127.0.0.1:8188:8188 \
  mmartial/comfyui-nvidia-docker:ubuntu24_cuda12.8-latest
```

This image is built for **RTX 50xx**; the README explicitly recommends the `ubuntu24_cuda12.8` tag and shows the **localhost-only** `-p 127.0.0.1:8188:8188` mapping. ([GitHub][2])

**Open the GUI:** [http://127.0.0.1:8188](http://127.0.0.1:8188) → **Templates → Image → Qwen-Image** or **Qwen-Image-Edit**. (Those are the official Comfy templates for Qwen.) ([ComfyUI][5])

---

## Two tiny gotchas (so you don’t wonder later)

* Your `nvidia-smi` shows **\~25 GB VRAM in use by Ollama**. If ComfyUI can’t allocate memory, stop it temporarily:

  ```bash
  systemctl --user stop ollama
  ```
* If you want to run Docker **without sudo**:

  ```bash
  sudo usermod -aG docker $USER
  newgrp docker
  ```

That’s it—GPU in Docker is now wired, ComfyUI runs on **localhost**, and the Qwen models are already in place.
