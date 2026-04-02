# LLM Inference Benchmarks

## Environment

- **Hardware:** AMD Radeon RX 7900 XTX (24 GB VRAM), Proxmox LXC container (VMID 103, "ollama")
- **Backend:** llama.cpp (build 95a6eba), Vulkan (RADV NAVI31)
- **Server:** llama-server, `--gpu-layers 99 --flash-attn on --parallel 2`
- **Host:** 192.168.1.103:8080, OpenAI-compatible API
- **Date:** 2026-04-02

## Backend Selection: Vulkan vs ROCm

Vulkan consistently outperforms ROCm (HIP) on RDNA3 hardware (7900 XTX) for llama.cpp inference.
This is a known issue tracked at ggml-org/llama.cpp#20934 and ROCm/ROCm#4883.
All benchmarks use the Vulkan backend.

## Raw Speed Benchmarks (llama-bench)

Test: pp512 (prompt processing, 512 tokens) and tg128 (token generation, 128 tokens), 3 repetitions.

### Dense Models (Qwen3.5-27B variants)

| Model | Quant | Size | pp512 (t/s) | tg128 (t/s) |
|-------|-------|------|-------------|-------------|
| Qwen3.5-27B base | Q4_K_M | 15.58 GiB | 722.7 +/- 1.9 | 40.3 +/- 0.1 |
| Qwen3.5-27B Opus v1 (i1) | Q4_0 | 14.45 GiB | 823.7 +/- 2.0 | 43.1 +/- 0.0 |
| Qwen3.5-27B Opus v2 (Jackrong) | Q4_K_M | 15.40 GiB | 720.7 +/- 2.1 | 40.6 +/- 0.1 |

### MoE Models

| Model | Quant | Size | pp512 (t/s) | tg128 (t/s) |
|-------|-------|------|-------------|-------------|
| GLM-4.7-Flash (30B, 3B active) | Q4_K_M | 17.05 GiB | 1986.8 +/- 85.7 | 135.4 +/- 0.3 |

### Speed Observations

- GLM-4.7-Flash is 2.7x faster on prompt processing and 3.4x faster on token generation than any Qwen variant, due to MoE architecture (only 3B active parameters).
- The Opus v1 i1-Q4_0 quant is ~6% faster than Q4_K_M variants due to smaller model size (14.45 vs 15.4-15.58 GiB). Token generation is memory-bandwidth-bound on dense models.
- Opus v2 Q4_K_M is identical speed to base Q4_K_M (same quant, same architecture, different fine-tune).

## VRAM Usage

Server config: `--ctx-size` as noted, `--parallel 2`.

| Model | Quant | ctx-size | Model VRAM | KV Cache | Compute | Total | Free |
|-------|-------|----------|------------|----------|---------|-------|------|
| Qwen3.5-27B base | Q4_K_M | 8192 | 15,273 MiB | 811 MiB | 495 MiB | 16,579 MiB | 7,964 MiB |
| Qwen3.5-27B Opus v1 | i1-Q4_0 | 131072 | 14,110 MiB | ~5,500 MiB | 629 MiB | ~20,239 MiB | ~4,321 MiB |
| Qwen3.5-27B Opus v2 | Q4_K_M | 131072 | 15,088 MiB | ~5,500 MiB | ~630 MiB | ~21,218 MiB | ~3,342 MiB |
| GLM-4.7-Flash | Q4_K_M | 8192 | 17,285 MiB | 423 MiB | 334 MiB | 18,042 MiB | 6,478 MiB |
| GLM-4.7-Flash | Q4_K_M | 32768 | 17,285 MiB | 1,692 MiB | 334 MiB | 19,311 MiB | 5,208 MiB |
| GLM-4.7-Flash | Q4_K_M | 131072 | 17,285 MiB | 6,768 MiB | ~334 MiB | ~24,387 MiB | ~173 MiB |

### VRAM Observations

- GLM-4.7-Flash at 128k context nearly exhausts 24 GB VRAM (~0.2 GB free). Not safe for production.
- GLM-4.7-Flash at 32k context is the sweet spot: 5.2 GB free, room for context growth.
- Qwen dense models have smaller KV caches than GLM at the same context size due to fewer layers.
- The `--parallel 2` flag doubles KV cache allocation (2 slots x ctx-size/2 per slot).

## Multi-Turn Reasoning Quality

### Methodology

Three multi-turn scenarios testing code debugging (3 turns), logic puzzle enumeration (2 turns), and distributed systems architecture (2 turns). Each scenario builds on prior turns, testing context retention and progressive reasoning.

Server config: `--ctx-size 131072`, API `max_tokens: 131072`.

### Test 1: Code Debugging (3 turns)

Turn 1: Find a bug in a linked list reverse function. Turn 2: Extend to doubly-linked list. Turn 3: Write a test harness with assert().

| Model | Turn 1 | Turn 2 | Turn 3 | Reasoning Overhead | Wall Time |
|-------|--------|--------|--------|--------------------|-----------|
| GLM-4.7-Flash | Correct, concise | Good code + edge cases | Complete (truncated tail) | 5,325 chars thinking | ~55s |
| Qwen Opus v1 | Correct, trace table | Good code + edge case table | Complete (truncated tail) | 3,202 chars thinking | ~85s |
| Qwen Opus v2 | Correct, trace table | Good code, self-corrected mid-answer | Complete (truncated tail) | 1,570 chars thinking | ~99s |

Winner: Qwen Opus v2. Shortest reasoning chain, self-corrected a mistake in turn 2, all answers correct.

### Test 2: Logic Puzzle Enumeration (2 turns)

Turn 1: Five people in a row with 4 constraints, list all valid arrangements. Turn 2: Add a 5th constraint, check which survive, verify completeness.

| Model | Turn 1 Arrangements Found | Turn 2 Survivors | Self-Correction | Total Tokens | Wall Time |
|-------|--------------------------|-----------------|-----------------|-------------|-----------|
| GLM-4.7-Flash | Incomplete (hit token limit) | Found 4 (incorrect, answer is 6) | No | 14,485 | ~110s |
| Qwen Opus v1 | 8 (correct) | 6 (correct), re-verified | Yes | 6,242 | ~142s |
| Qwen Opus v2 | 8 (correct) | 6 (correct), re-verified from scratch | Yes | 3,490 | ~88s |

Winner: Qwen Opus v2. Correct on both turns, half the tokens of v1, fastest wall time. GLM got the answer wrong.

### Test 3: Distributed Systems Architecture (2 turns)

Turn 1: Design a distributed rate limiter (50k req/s, 8 nodes, per-user + global limits, burst). Turn 2: Analyze failure mode during network partition (3 nodes lose Redis).

| Model | Turn 1 Quality | Turn 2 Quality | ASCII Diagrams | Total Tokens | Wall Time |
|-------|---------------|---------------|----------------|-------------|-----------|
| GLM-4.7-Flash | Token bucket + Redis Lua, partial | Conservative local fallback (1 req/s) | No | 6,742 | ~63s |
| Qwen Opus v1 | Token bucket + Redis, key format detail | Circuit breaker state machine, 12.5% degraded | Yes | 7,599 | ~161s |
| Qwen Opus v2 | Dual-layer arch, burst parameters | Detailed partition walkthrough, diagrams | Yes | 8,284 | ~211s |

Winner: Qwen Opus v2. Most complete architecture with ASCII diagrams, explicit burst parameters, and detailed partition analysis.

### Historical Note: 4096 max_tokens Bug

Early tests were run with `max_tokens: 4096` due to a script bug. Both GLM and Qwen models frequently returned empty visible content because internal reasoning chains consumed the entire token budget. Thinking models (GLM-4.7-Flash especially) require high `max_tokens` limits (16k+) to produce visible output.

## Model Comparison Summary

| Metric | GLM-4.7-Flash | Qwen Opus v1 (i1-Q4_0) | Qwen Opus v2 (Q4_K_M) |
|--------|--------------|------------------------|------------------------|
| Generation speed | 135 t/s | 43 t/s | 41 t/s |
| Prompt processing | 1,987 t/s | 824 t/s | 721 t/s |
| Model size (VRAM) | 17.3 GB | 14.1 GB | 15.1 GB |
| Reasoning correctness | Failed logic puzzle | Correct | Correct |
| Token efficiency | Poor (huge thinking chains, empty outputs) | Good | Best (24% shorter chains) |
| Self-correction | No | Yes | Yes |
| Architecture depth | Adequate | Good | Excellent |

## Production Configuration

Based on these benchmarks, the production configuration is:

```
Model:    Qwen3.5-27B-Claude-4.6-Opus-Reasoning-Distilled-v2 (Jackrong) Q4_K_M
File:     /opt/qwen35-27b-opus-v2-q4km.gguf (16 GB)
Backend:  Vulkan (RADV NAVI31)
Context:  32768 tokens
Parallel: 2 slots
GPU:      99 layers (fully offloaded)
Flash:    on
```

Systemd unit: `/etc/systemd/system/llama-server.service`

```ini
[Unit]
Description=llama.cpp Server (Vulkan)
After=network.target

[Service]
Type=simple
ExecStart=/opt/llama.cpp/build/bin/llama-server \
    --model /opt/qwen35-27b-opus-v2-q4km.gguf \
    --gpu-layers 99 \
    --ctx-size 32768 \
    --host 0.0.0.0 \
    --port 8080 \
    --alias qwen3.5-27b-opus-v2 \
    --parallel 2 \
    --flash-attn on
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

## Model Sources

| Model | HuggingFace Repo | File |
|-------|-------------------|------|
| Qwen3.5-27B base Q4_K_M | bartowski/Qwen_Qwen3.5-27B-GGUF | qwen35-27b-q4km.gguf |
| Qwen3.5-27B Opus v1 i1-Q4_0 | (unknown provenance) | qwen35-27b-opus-i1-q4_0.gguf |
| Qwen3.5-27B Opus v2 Q4_K_M | Jackrong/Qwen3.5-27B-Claude-4.6-Opus-Reasoning-Distilled-v2-GGUF | Qwen3.5-27B.Q4_K_M.gguf |
| GLM-4.7-Flash Q4_K_M | unsloth/GLM-4.7-Flash-GGUF | GLM-4.7-Flash-Q4_K_M.gguf |
