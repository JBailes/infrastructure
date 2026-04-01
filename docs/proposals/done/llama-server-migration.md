# Migrate CT 103 from Ollama to llama.cpp (Vulkan)

## Problem

CT 103 runs Ollama with AMD 7900XTX GPU passthrough for local LLM inference.
Benchmarking revealed that Ollama's bundled ROCm backend significantly
underperforms on this hardware -- decode throughput is only 28 tok/s on a
27B Q4_K_M model, roughly 46% of the card's theoretical memory-bandwidth
ceiling (~60 tok/s).

## Benchmarks

**Model:** Qwen3.5-27B Q4_K_M (15.58 GiB)
**Hardware:** AMD Radeon RX 7900 XTX (24 GB VRAM, 960 GB/s bandwidth)
**Container:** CT 103 (Proxmox LXC, privileged, GPU passthrough)

| Engine | Backend | Prompt (tok/s) | Decode (tok/s) | % of theoretical |
|--------|---------|---------------:|---------------:|-----------------:|
| Ollama 0.19.0 | ROCm 7.2 (bundled) | 75.8 | 27.5 | 46% |
| llama.cpp b8611 | Vulkan (Mesa RADV 25.0.7) | 726.5 | 40.3 | 67% |

- **Decode throughput:** +47% (40.3 vs 27.5 tok/s)
- **Prompt processing:** ~10x faster (726.5 vs 75.8 tok/s)
- Flash attention made no measurable difference on Vulkan (40.4 vs 40.3)

### Why Ollama is slower

Ollama bundles its own ROCm 7.2 runtime in `/usr/lib/ollama/rocm/`. The
`libggml-hip.so` is a 733 MB monolithic shared object compiled for multiple
GPU architectures. This self-contained approach avoids SDK installation but
introduces overhead in the HIP->HSA dispatch path compared to Vulkan's
direct driver path via Mesa RADV.

### Why Vulkan

- No proprietary SDK required -- Mesa's RADV driver provides Vulkan 1.4 with
  cooperative matrix extensions (KHR_coopmat) out of the box on Debian Trixie
- Builds from source in ~5 minutes with standard packages (`libvulkan-dev`,
  `glslc`, `mesa-vulkan-drivers`)
- Broadly portable across AMD (RDNA2+), NVIDIA, and Intel Arc GPUs

## Approach

Replace Ollama with llama.cpp's `llama-server` using the Vulkan backend.

### Changes

| Before | After |
|--------|-------|
| Ollama 0.19.0 on :11434 | llama-server (llama.cpp) on :8080 |
| ROCm 7.2 (bundled by Ollama) | Vulkan (Mesa RADV 25.0.7) |
| `ollama.service` | `llama-server.service` |
| Model managed by `ollama pull` | GGUF file at `/opt/models/*.gguf` |
| Hostname: ollama | Hostname: llm |

### Container spec (unchanged)

| Property | Value |
|----------|-------|
| CTID | 103 |
| IP | 192.168.1.103 |
| RAM | 64 GB |
| Disk | 256 GB |
| CPU | 8 cores |
| GPU | AMD 7900XTX via /dev/dri + /dev/kfd |

### Service configuration

```ini
[Service]
ExecStart=/opt/llama.cpp/build/bin/llama-server \
    --model /opt/models/qwen35-27b-q4km.gguf \
    --gpu-layers 99 \
    --ctx-size 8192 \
    --host 0.0.0.0 \
    --port 8080 \
    --alias qwen3.5-27b \
    --parallel 2 \
    --flash-attn on
```

### API compatibility

llama-server provides the same OpenAI-compatible endpoints Ollama did:
- `GET /v1/models`
- `POST /v1/chat/completions`
- `POST /v1/completions`

Clients using the OpenAI API format (including aimee delegates) require only
an endpoint change from `:11434/v1` to `:8080/v1`.

### Model management

Models are now plain GGUF files in `/opt/models/` rather than Ollama's blob
storage. To swap models, download a GGUF from HuggingFace and update the
systemd service ExecStart path. To serve multiple models, run multiple
llama-server instances on different ports.

## Files changed

| File | Change |
|------|--------|
| `homelab/bootstrap/11-setup-ollama.sh` | Rewritten to build llama.cpp with Vulkan and configure llama-server |
| `homelab/README.md` | Updated host table: ollama -> llm, :11434 -> :8080 |
| `homelab/diagrams.md` | Updated network diagram and host reference table |

## Rollback

Re-enable Ollama:
```bash
systemctl stop llama-server && systemctl disable llama-server
systemctl enable ollama && systemctl start ollama
```

The Ollama binary and model blobs remain on disk and are not removed.
