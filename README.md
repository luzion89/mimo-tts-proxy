# mimo-tts-proxy

小米 MiMo TTS 的 **OpenAI 兼容网关**:对外提供标准的 `POST /v1/audio/speech` 接口,供 Anx Reader(安读)等只支持 OpenAI TTS 格式的阅读器朗读本地电子书(epub/mobi/txt 等)。

## 项目初衷

作者日常用安卓阅读器 [Anx Reader(安读)](https://github.com/Anxcye/anx-reader)听本地电子书,该软件只支持 OpenAI 的 `/v1/audio/speech` 接口格式;而作者充值的小米 MiMo TTS 走的是 Chat Completions 接口、音频以 base64 返回,两者完全异构,无法直接对接。为了不浪费已充值的 MiMo 额度,便写了这个本地轻量网关:对外提供 OpenAI 兼容接口,对内转接小米 MiMo TTS,并通过 Cloudflare 隧道开放给手机 App 使用。

## 特性

- 完整适配 OpenAI `/v1/audio/speech` 请求格式(`model` / `input` / `voice` / `response_format` / `speed` / `instructions`)
- 自动完成格式转换:OpenAI 音色名 → MiMo 音色、语速 → MiMo 朗读指令、不支持的音频格式自动回退
- 音频解码:MiMo 返回的 base64 音频转为原始字节流,响应行为与 OpenAI 一致
- 附带 `/v1/models`、`/health` 端点,便于调试
- 自带 Cloudflare 隧道脚本,一键开放公网

## 安全架构(重要)

本项目使用**两层密钥**设计,小米的真实 API Key 永远不会离开你的电脑:

```
┌─────────┐  App 持有:代理密钥(本地随机生成)   ┌──────────────────┐
│ 手机 App │ ──────── HTTPS 隧道 ────────────> │ 本机代理(网关)    │
│AnxReader│ <────────── 音频流 ─────────────── │ 持有:小米 API Key │
└─────────┘                                   └────────┬─────────┘
                                                        │ 本机直连
                                                        ▼
                                              小米 MiMo API
```

1. **小米 API Key(上游)**:只存在本机 `.env`,由代理在本地调用上游时使用,**不对 App、不对公网暴露**。
2. **代理密钥(`PROXY_API_KEY`)**:发给 App 使用的不是小米 key,而是**本地随机生成的密钥**(`secrets.token_urlsafe(24)`),首次启动时自动生成并写入 `.env`,可随时打开文件修改。即使公网地址被他人得知,没有这个密钥也无法消耗你的 MiMo 余额。
3. **传输加密**:App 与网关之间经 Cloudflare 隧道全程 TLS 加密。
4. 本仓库不包含任何真实密钥;所有密钥仅存于本机 `.env`(请勿提交到任何公开仓库)。

## 工作原理

```
AnxReader ──(OpenAI 格式)──> 本代理 /v1/audio/speech
                                  │ 字段映射: model/voice/speed/instructions/format
                                  ▼
              小米 MiMo /v1/chat/completions (mimo-v2.5-tts)
                                  │ 响应 JSON 中 base64 音频
                                  ▼
              解码为原始音频字节返回 AnxReader
```

> 小米 MiMo TTS 复用 Chat Completions 接口(文本放 `assistant` 消息、音色放 `audio.voice`、音频以 base64 返回于 `choices[0].message.audio.data`),与 OpenAI 的 `audio/speech` 完全异构,因此需要本网关。

## 快速开始

1. 复制 `.env.example` 为 `.env`,填入 `MIMO_API_KEY`(小米 MiMo 开放平台获取)。
   `PROXY_API_KEY` **无需手动填写**——`start.sh` 首次启动时会自动本地随机生成并写入。
2. 运行 `./start.sh`:自动安装依赖、启动本地服务(默认 8787 端口)与 Cloudflare 隧道,最后打印公网地址和 App 密钥。
3. 停止:`./stop.sh`。

## Anx Reader 配置

设置 → 朗读 → TTS 服务选 **OpenAI**,填写:

| 字段 | 值 |
|---|---|
| URL | `https://<隧道地址>/v1/audio/speech`(`start.sh` 输出的地址;必须带完整路径) |
| API Key | `.env` 里的 `PROXY_API_KEY`(`start.sh` 也会直接打印) |
| Model | 任意值(如 `tts-1`,会被重写为 `mimo-v2.5-tts`) |
| Voice | 直接粘贴 MiMo 音色名,或 OpenAI 音色名(自动映射) |
| Instructions | 留空,或用中文写风格指令(见下) |

填完点「测试」,听到声音即成功。

## 音色与风格

### 预置音色

| 音色 | 语言 / 风格 |
|---|---|
| 冰糖 | 中文女声·活泼 |
| 茉莉 | 中文女声·知性 |
| 苏打 | 中文男声·少年 |
| 白桦 | 中文男声·成熟 |
| Mia / Chloe | 英文女声 |
| Milo / Dean | 英文男声 |

OpenAI 音色名自动映射(可在 `.env` 用 `VOICE_MAP` 覆盖):`alloy→Mia`、`echo→茉莉`、`fable→苏打`、`nova/shimmer→冰糖`、`onyx→白桦`、`ash→Dean`、`coral→Chloe`、`sage→Milo`。

### 风格微调

- **Instructions 字段**:MiMo 支持自然语言风格指令,如「用温柔舒缓的语气朗读,像深夜电台主播」。
- **风格标签**:`(东北话)`、`(粤语)`、`(四川话)`、`(温柔)`、`(兴奋)`、`(唱歌)` 等。
- **语速**:AnxReader 的语速滑条会经代理转为 MiMo 朗读指令。

### 功能范围

本网关只做 OpenAI `/v1/audio/speech` 格式兼容。OpenAI 该格式本身不支持的 MiMo 能力(**音色克隆** `mimo-v2.5-tts-voiceclone`、**音色设计** `mimo-v2.5-tts-voicedesign`)不在本项目范围内。

## 配置项(`.env`)

| 变量 | 说明 |
|---|---|
| `MIMO_API_KEY` | 小米 MiMo 开放平台 API Key(必填) |
| `MIMO_API_BASE` | 上游地址;Token-Plan 国内集群可改为 `https://token-plan-cn.xiaomimimo.com/v1` |
| `MIMO_TTS_MODEL` | 上游模型,默认 `mimo-v2.5-tts` |
| `PROXY_API_KEY` | 给 App 的访问密钥,本地随机生成,可修改 |
| `DEFAULT_VOICE` | 默认音色(未指定时),默认 `冰糖` |
| `DEFAULT_FORMAT` | 默认/回退格式,默认 `mp3`(MiMo 支持 wav/mp3/pcm/pcm16) |
| `VOICE_MAP` | 自定义 OpenAI→MiMo 音色映射,如 `alloy=冰糖,echo=茉莉` |
| `PORT` | 本地端口,默认 `8787` |

## 运维与故障排查

- **隧道地址每次重启会变**:`start.sh` 会打印新地址,重启后需在 AnxReader 更新 URL。需要固定地址可注册 Cloudflare 账号绑定域名(命名隧道)。
- **修改代理密钥**:直接编辑 `.env` 的 `PROXY_API_KEY` 后运行 `./start.sh` 生效。
- 长段落朗读报错时,在 AnxReader 里调小朗读分段长度。

| 现象 | 原因 |
|---|---|
| 401 invalid proxy api key | App 里 API Key 与 `.env` 的 `PROXY_API_KEY` 不一致 |
| 401 Invalid API Key | `.env` 的 `MIMO_API_KEY` 错误或已撤销 |
| 402 | MiMo 余额不足 |
| 404 | URL 没带 `/v1/audio/speech` 完整路径 |
| 服务启动失败 / 无隧道地址 | 查看 `server.log` / `tunnel.log` |
