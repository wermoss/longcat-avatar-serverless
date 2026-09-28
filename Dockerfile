# LongCat-Video-Avatar 1.5 (ComfyUI + Kijai WanVideoWrapper) — RunPod serverless worker.
# Based on runpod-workers/worker-comfyui's own Dockerfile pattern, stripped to just what
# this one model needs: WanVideoWrapper + MelBandRoFormer + VideoHelperSuite custom nodes,
# and the LongCat Avatar model set baked into the image (no network volume, same tradeoff
# as our existing ltx25-i2v endpoint: every cold start re-downloads if not baked in, so we
# bake in — see CLAUDE.md section 2).
ARG BASE_IMAGE=nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04

# ---- Stage 1: ComfyUI + custom nodes ----
FROM ${BASE_IMAGE} AS base

ARG COMFYUI_VERSION=0.34.0
ARG CUDA_VERSION_FOR_COMFY=12.8

ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_PREFER_BINARY=1
ENV PYTHONUNBUFFERED=1
ENV CMAKE_BUILD_PARALLEL_LEVEL=8

RUN apt-get update && apt-get install -y \
    python3.12 python3.12-venv git wget \
    libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 ffmpeg openssh-server \
    && ln -sf /usr/bin/python3.12 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip \
    && apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*

RUN wget -qO- https://astral.sh/uv/install.sh | sh \
    && ln -s /root/.local/bin/uv /usr/local/bin/uv \
    && ln -s /root/.local/bin/uvx /usr/local/bin/uvx \
    && uv venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

RUN uv pip install comfy-cli==1.13.0 pip setuptools wheel
RUN /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --cuda-version "${CUDA_VERSION_FOR_COMFY}" --nvidia

# LongCat Avatar's three custom node packages (all confirmed working together against
# the official example workflow — see workflow_api.json / longcat-serverless R&D 2026-09-28).
WORKDIR /comfyui/custom_nodes
RUN git clone --depth 1 https://github.com/kijai/ComfyUI-WanVideoWrapper.git \
    && git clone --depth 1 https://github.com/kijai/ComfyUI-MelBandRoFormer.git \
    && git clone --depth 1 https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git

RUN uv pip install torch==2.11.0 torchvision==0.26.0 torchaudio==2.11.0 \
      --index-url https://download.pytorch.org/whl/cu128 \
    && uv pip install -r /comfyui/requirements.txt \
    && for r in /comfyui/custom_nodes/*/requirements.txt; do \
         [ -f "$r" ] && uv pip install -r "$r" || true; \
       done \
    && uv pip install "transformers>=4.50.3,<5" "huggingface-hub<1.0"

# Build-time smoke test: catches a startup-breaking import error here, not on a live worker.
# Bounded to 60s and made non-fatal (`|| true`) — verified by hand (2026-09-29, debug pod) that
# all custom nodes here (WanVideoWrapper, MelBandRoFormer, VideoHelperSuite) import cleanly in
# ~3s; the only thing that can make this hang past that is ComfyUI-Manager (base image, not one
# of ours) getting stuck on its `comfyregistry` lookup when that host isn't reachable from the
# build sandbox, which the original 300s-and-fatal version turned into a full build failure with
# no useful traceback surfaced in RunPod's Hub build log.
RUN cd /comfyui && (timeout 60 python main.py --quick-test-for-ci --cpu || true)

WORKDIR /comfyui
ADD src/extra_model_paths.yaml ./
WORKDIR /
RUN uv pip install runpod requests websocket-client
ADD src/start.sh src/network_volume.py handler.py test_input.json ./
RUN chmod +x /start.sh
COPY scripts/comfy-node-install.sh /usr/local/bin/comfy-node-install
RUN chmod +x /usr/local/bin/comfy-node-install
ENV PIP_NO_INPUT=1
COPY scripts/comfy-manager-set-mode.sh /usr/local/bin/comfy-manager-set-mode
RUN chmod +x /usr/local/bin/comfy-manager-set-mode
CMD ["/start.sh"]

# ---- Stage 2: bake in the LongCat Avatar model set (~26GB, fp8 diffusion + fp8 text encoder) ----
FROM base AS downloader
WORKDIR /comfyui
RUN mkdir -p models/diffusion_models models/vae models/text_encoders models/loras models/wav2vec2

# Diffusion model — fp8 scaled, ~17GB (bf16 original is 32GB; not worth the cold-start cost).
RUN wget -q -O models/diffusion_models/LongCat-Avatar-single_fp8_e4m3fn_scaled_mixed_KJ.safetensors \
    https://huggingface.co/Kijai/LongCat-Video_comfy/resolve/main/Avatar/LongCat-Avatar-single_fp8_e4m3fn_scaled_mixed_KJ.safetensors
# Vocal separator, shares the diffusion_models folder per ComfyUI-MelBandRoFormer's own loader.
RUN wget -q -O models/diffusion_models/MelBandRoformer_fp32.safetensors \
    https://huggingface.co/Kijai/MelBandRoFormer_comfy/resolve/main/MelBandRoformer_fp32.safetensors
RUN wget -q -O models/vae/Wan2_1_VAE_bf16.safetensors \
    https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1_VAE_bf16.safetensors
RUN wget -q -O models/text_encoders/umt5-xxl-enc-fp8_e4m3fn.safetensors \
    https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-fp8_e4m3fn.safetensors
RUN wget -q -O models/loras/LongCat_distill_lora_alpha64_bf16.safetensors \
    https://huggingface.co/Kijai/LongCat-Video_comfy/resolve/main/LongCat_distill_lora_alpha64_bf16.safetensors
RUN wget -q -O models/wav2vec2/wav2vec2-chinese-base_fp16.safetensors \
    https://huggingface.co/Kijai/wav2vec2_safetensors/resolve/main/wav2vec2-chinese-base_fp16.safetensors

# ---- Stage 3: final image ----
FROM base AS final
COPY --from=downloader /comfyui/models /comfyui/models
