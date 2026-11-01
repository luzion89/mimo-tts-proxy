import base64
import logging
import os

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")

import httpx
from dotenv import load_dotenv
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response

load_dotenv()

MIMO_API_BASE = os.getenv("MIMO_API_BASE", "https://api.xiaomimimo.com/v1")
MIMO_API_KEY = os.getenv("MIMO_API_KEY", "")
MIMO_TTS_MODEL = os.getenv("MIMO_TTS_MODEL", "mimo-v2.5-tts")
PROXY_API_KEY = os.getenv("PROXY_API_KEY", "")
DEFAULT_VOICE = os.getenv("DEFAULT_VOICE", "冰糖")
DEFAULT_FORMAT = os.getenv("DEFAULT_FORMAT", "mp3")

# OpenAI 音色名 -> MiMo 音色, 可通过 .env 的 VOICE_MAP 覆盖 (alloy=冰糖,echo=茉莉)
VOICE_MAP = {
    "alloy": "Mia",
    "ash": "Dean",
    "coral": "Chloe",
    "echo": "茉莉",
    "fable": "苏打",
    "nova": "冰糖",
    "onyx": "白桦",
    "sage": "Milo",
    "shimmer": "冰糖",
}
for pair in os.getenv("VOICE_MAP", "").split(","):
    if "=" in pair:
        k, v = pair.split("=", 1)
        VOICE_MAP[k.strip().lower()] = v.strip()

SUPPORTED_FORMATS = {"wav", "mp3", "pcm", "pcm16"}
CONTENT_TYPES = {
    "mp3": "audio/mpeg",
    "wav": "audio/wav",
    "pcm": "audio/L16",
    "pcm16": "audio/L16",
}

app = FastAPI(title="mimo-tts-proxy")


def error(message: str, status_code: int = 400):
    return JSONResponse(
        {"error": {"message": message, "type": "invalid_request_error"}},
        status_code=status_code,
    )


def speed_hint(speed):
    if speed is None or speed == 1.0:
        return ""
    if speed <= 0.5:
        return "语速非常慢"
    if speed < 1.0:
        return "语速慢一些"
    if speed >= 2.0:
        return "语速非常快"
    return "语速快一些"


@app.get("/health")
async def health():
    return {"status": "ok", "upstream_configured": bool(MIMO_API_KEY)}


@app.get("/v1/models")
@app.get("/models")
async def models():
    return {
        "object": "list",
        "data": [{"id": MIMO_TTS_MODEL, "object": "model", "owned_by": "xiaomi"}],
    }


@app.post("/v1/audio/speech")
@app.post("/audio/speech")
async def speech(request: Request):
    if PROXY_API_KEY:
        auth = request.headers.get("authorization", "")
        logging.info("request auth: %s...", auth[:16] if auth else "<empty>")
        if auth not in (f"Bearer {PROXY_API_KEY}", PROXY_API_KEY):
            return error("invalid proxy api key", 401)

    try:
        body = await request.json()
    except Exception:
        return error("invalid JSON body", 400)

    text = str(body.get("input") or "").strip()
    if not text:
        return error("input is required", 400)

    voice = str(body.get("voice") or "").strip()
    voice = VOICE_MAP.get(voice.lower(), voice) or DEFAULT_VOICE

    fmt = str(body.get("response_format") or DEFAULT_FORMAT).lower()
    if fmt not in SUPPORTED_FORMATS:
        fmt = DEFAULT_FORMAT

    speed = body.get("speed")
    try:
        speed = min(max(float(speed), 0.25), 4.0) if speed is not None else None
    except (TypeError, ValueError):
        speed = None

    instructions = str(body.get("instructions") or "").strip()
    hint = speed_hint(speed)
    if hint:
        instructions = f"{instructions}，{hint}" if instructions else hint

    messages = []
    if instructions:
        messages.append({"role": "user", "content": instructions})
    messages.append({"role": "assistant", "content": text})

    payload = {
        "model": MIMO_TTS_MODEL,
        "messages": messages,
        "audio": {"format": fmt, "voice": voice},
        "stream": False,
    }

    headers = {"Content-Type": "application/json"}
    if MIMO_API_KEY:
        if MIMO_API_KEY.startswith("tp-"):
            headers["api-key"] = MIMO_API_KEY
        else:
            headers["Authorization"] = f"Bearer {MIMO_API_KEY}"

    try:
        async with httpx.AsyncClient(timeout=120) as client:
            r = await client.post(
                f"{MIMO_API_BASE}/chat/completions", json=payload, headers=headers
            )
    except httpx.HTTPError as e:
        return JSONResponse(
            {"error": {"message": f"upstream error: {e}", "type": "api_error"}},
            status_code=502,
        )

    if r.status_code != 200:
        return JSONResponse(
            {"error": {"message": f"upstream {r.status_code}: {r.text[:500]}", "type": "api_error"}},
            status_code=r.status_code,
        )

    try:
        audio_b64 = r.json()["choices"][0]["message"]["audio"]["data"]
    except (KeyError, IndexError, TypeError, ValueError):
        return JSONResponse(
            {"error": {"message": "unexpected upstream response", "type": "api_error"}},
            status_code=502,
        )

    try:
        audio_bytes = base64.b64decode(audio_b64)
    except Exception:
        return JSONResponse(
            {"error": {"message": "failed to decode audio", "type": "api_error"}},
            status_code=502,
        )

    return Response(
        content=audio_bytes,
        media_type=CONTENT_TYPES.get(fmt, "application/octet-stream"),
    )
