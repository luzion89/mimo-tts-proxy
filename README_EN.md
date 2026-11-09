# mimo-tts-proxy

An **OpenAI-compatible gateway for Xiaomi MiMo TTS**: exposes the standard `POST /v1/audio/speech` endpoint so that ebook readers that only support OpenAI's TTS format — such as [Anx Reader](https://github.com/Anxcye/anx-reader) — can read local ebooks (epub/mobi/txt) aloud with MiMo voices.

Runs on Linux/macOS and Windows. Public access can use **Tailscale Funnel** (stable URL) or a Cloudflare quick tunnel.

[中文文档](README.md)

## Motivation

I listen to local ebooks on Android with Anx Reader, which only supports the OpenAI `/v1/audio/speech` API format. Xiaomi MiMo TTS (which I had already paid for) uses a Chat Completions-style API and returns audio as base64 inside JSON — completely incompatible with what Anx Reader expects. Rather than wasting my MiMo credits, I built this lightweight local gateway: an OpenAI-compatible API on the outside, a MiMo TTS client on the inside, exposed to my phone via a Cloudflare tunnel or Tailscale Funnel.

## Features

- Full OpenAI `/v1/audio/speech` request compatibility (`model` / `input` / `voice` / `response_format` / `speed` / `instructions`)
- Automatic field mapping: OpenAI voice names → MiMo voices, speed → MiMo narration instructions, unsupported audio formats fall back to `mp3`
- Decodes MiMo's base64 audio into a raw byte stream, so responses behave exactly like OpenAI's
- Ships with `/v1/models` and `/health` endpoints for debugging
- One-command Cloudflare quick tunnel for public access (the URL changes on every restart)
- Optional **Tailscale Funnel**: stable public URL across restarts, with automatic fallback to a Cloudflare quick tunnel
- Windows PowerShell scripts: one-command start/stop, a logon-triggered scheduled task, and automatic restart on failure

## Security architecture

Two-layer key design — your real Xiaomi API key never leaves your machine:

```
┌─────────┐  App holds: proxy key (random, local)   ┌──────────────────────┐
│  Phone   │ ─────────── HTTPS tunnel ────────────> │ Local gateway (proxy)│
│AnxReader│ <─────────── audio stream ───────────── │ Holds: MiMo API key  │
└─────────┘                                         └──────────┬───────────┘
                                                               │ local direct call
                                                               ▼
                                                         Xiaomi MiMo API
```

1. **Xiaomi API key (upstream)**: stored only in the local `.env`; used by the gateway when calling MiMo locally. It is **never exposed to the app or the public internet**.
2. **Proxy key (`PROXY_API_KEY`)**: what the app actually sends is **not** your Xiaomi key — it is a key **randomly generated on your machine** (`secrets.token_urlsafe(24)`), auto-written to `.env` on first start and editable at any time. Even if the public URL leaks, nobody can burn your credits without this key.
3. **Encrypted transport**: app-to-gateway traffic is TLS-encrypted through a Cloudflare tunnel or Tailscale Funnel. With Funnel, TLS terminates on your own machine and Tailscale relays only encrypted bytes; a Cloudflare tunnel terminates TLS at Cloudflare's edge.
4. No real keys are stored in this repository; keys live only in your local `.env` (never commit it).

## How it works

```
AnxReader ──(OpenAI format)──> gateway /v1/audio/speech
                                   │ field mapping: model/voice/speed/instructions/format
                                   ▼
              Xiaomi MiMo /v1/chat/completions (mimo-v2.5-tts)
                                   │ base64 audio in JSON response
                                   ▼
              decoded to raw audio bytes and returned to AnxReader
```

> MiMo TTS reuses the Chat Completions API (text goes into an `assistant` message, voice into `audio.voice`, and the audio is returned base64-encoded at `choices[0].message.audio.data`), which is entirely different from OpenAI's `audio/speech` — hence this gateway.

## Quick start

1. Copy `.env.example` to `.env` and fill in `MIMO_API_KEY` (from the MiMo open platform).
   You do **not** need to fill in `PROXY_API_KEY` — the start script generates it randomly on first start and writes it into `.env`.
2. Run the start script: it installs dependencies, starts the local server (port 8787 by default), opens public access with whichever option is available, and prints the public URL and app key.
3. Stop with `./stop.sh` (Windows: `.\stop.ps1`).

### Linux / macOS

```bash
./start.sh   # local server + Cloudflare quick tunnel
./stop.sh
```

### Windows (Tailscale Funnel recommended)

Requires Python 3. Pick one public-access option:

- **Tailscale Funnel (recommended)**: stable URL across restarts. Install Tailscale (`winget install Tailscale.Tailscale`), sign in, enable **HTTPS Certificates** and **Funnel** in the admin console, then run:

  ```powershell
  tailscale funnel --bg 8787
  ```

- **Cloudflare quick tunnel (fallback)**: no account needed, but the URL changes on every start and dies with the process. Install cloudflared (`winget install Cloudflare.cloudflared`) and `start.ps1` will use it automatically.

```powershell
copy .env.example .env   # edit .env and set MIMO_API_KEY
powershell -ExecutionPolicy Bypass -File .\start.ps1
powershell -ExecutionPolicy Bypass -File .\stop.ps1
```

`start.ps1` will:

- create `.venv`, install dependencies, and start the local server (via the `mimo-tts-proxy` scheduled task when present, otherwise in the background);
- use Tailscale Funnel when configured, otherwise fall back to a Cloudflare quick tunnel;
- register the logon-triggered scheduled task `mimo-tts-proxy` (running `run-server.ps1`) on first run, with up to 3 automatic restarts.

Logs: `server-task.log` (server output) and `task-diag.log` (start/stop details). `stop.ps1` stops the scheduled task before releasing the port.

> Note: Funnel exposes a public URL. `/v1/audio/speech` is protected by `PROXY_API_KEY`; `/health` and `/v1/models` remain public.

## Anx Reader configuration

Settings → Narrate → TTS service: **OpenAI**, then fill in:

| Field | Value |
|---|---|
| URL | `https://<public-url>/v1/audio/speech` (the URL printed by the start script; stable with Tailscale Funnel; full path required) |
| API Key | `PROXY_API_KEY` from `.env` (also printed by the start script) |
| Model | anything (e.g. `tts-1` — rewritten to `mimo-v2.5-tts`) |
| Voice | paste a MiMo voice name directly, or an OpenAI voice name (auto-mapped) |
| Instructions | leave empty, or write style instructions (see below) |

Tap **Test** — if you hear audio, it works.

## Voices & styles

### Preset voices

| Voice | Language / style |
|---|---|
| 冰糖 (Bingtang) | Chinese female · lively |
| 茉莉 (Moli) | Chinese female · gentle, intellectual |
| 苏打 (Suda) | Chinese male · youthful |
| 白桦 (Baihua) | Chinese male · mature |
| Mia / Chloe | English female |
| Milo / Dean | English male |

OpenAI voice names are auto-mapped (override via `VOICE_MAP` in `.env`): `alloy→Mia`, `echo→茉莉`, `fable→苏打`, `nova/shimmer→冰糖`, `onyx→白桦`, `ash→Dean`, `coral→Chloe`, `sage→Milo`.

### Style tweaks

- **Instructions field**: MiMo accepts natural-language style instructions, e.g. "read in a gentle, soothing tone, like a late-night radio host".
- **Style tags**: `(东北话)` Northeastern accent, `(粤语)` Cantonese, `(四川话)` Sichuanese, `(温柔)` gentle, `(兴奋)` excited, `(唱歌)` singing, etc.
- **Speed**: Anx Reader's speed slider is converted into MiMo narration instructions by the gateway.

### Scope

This gateway only provides OpenAI `/v1/audio/speech` format compatibility. MiMo features that have no equivalent in OpenAI's format (**voice cloning** `mimo-v2.5-tts-voiceclone`, **voice design** `mimo-v2.5-tts-voicedesign`) are out of scope.

## Configuration (`.env`)

| Variable | Description |
|---|---|
| `MIMO_API_KEY` | Xiaomi MiMo open platform API key (required) |
| `MIMO_API_BASE` | Upstream base URL; Token-Plan users in China may use `https://token-plan-cn.xiaomimimo.com/v1` |
| `MIMO_TTS_MODEL` | Upstream model, default `mimo-v2.5-tts` |
| `PROXY_API_KEY` | App-facing access key; generated locally, editable |
| `DEFAULT_VOICE` | Default voice, `冰糖` |
| `DEFAULT_FORMAT` | Default/fallback format, `mp3` (MiMo supports wav/mp3/pcm/pcm16) |
| `VOICE_MAP` | Custom OpenAI→MiMo voice mapping, e.g. `alloy=冰糖,echo=茉莉` |
| `PORT` | Local port, default `8787` |

## Operations & troubleshooting

- **Is the URL stable?** Tailscale Funnel keeps a stable URL across restarts. A Cloudflare quick tunnel gets a new URL on every start, and the old hostname stops resolving as soon as the process exits.
- **Changing the proxy key**: edit `PROXY_API_KEY` in `.env`, then restart (Windows: `.\stop.ps1` then `.\start.ps1`).
- **Windows service not running**: check `Get-ScheduledTask -TaskName mimo-tts-proxy`; see `task-diag.log` / `server-task.log`.
- **After a Windows reboot**: the scheduled task runs at user logon; Tailscale Funnel is restored by the Tailscale system service.
- If long passages fail, reduce Anx Reader's narration segment length.

| Symptom | Cause |
|---|---|
| 401 invalid proxy api key | App API key doesn't match `PROXY_API_KEY` in `.env` |
| 401 Invalid API Key | `MIMO_API_KEY` is wrong or revoked |
| 402 | MiMo balance exhausted |
| 404 | URL missing the full `/v1/audio/speech` path |
| Tailscale Funnel hostname does not resolve | Funnel is not enabled: check `tailscale funnel status` and enable HTTPS + Funnel in the admin console |
| Server fails to start / no tunnel URL | check `server.log` / `tunnel.log`; on Windows see `task-diag.log` |
