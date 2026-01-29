# hayase-vlc-bridge
Send Hayase Watch streams to a remote VLC player with automatic local fallback, fail-fast behavior, and configurable logging.
Works with any VLC instance exposing a WebSocket interface.
Designed for reliable external playback with minimal friction.

---

## What It Does

When you press **Play** in Hayase:

1. The script receives the streaming URL  
2. Rewrites `localhost` to a LAN IP reachable by your remote device  
3. Normalizes the URL encoding  
4. Sends the stream to VLC via WebSocket  
5. Falls back to local VLC if the remote player is unavailable  

**Result:** your Apple TV (or any remote device) plays the stream instantly.

---

## Why This Exists

Hayase streams content through a local HTTP server.

Remote devices cannot access:

```
localhost
127.0.0.1
```

This bridge makes the stream reachable without requiring manual interaction.

---

## Features

- Automatic remote playback  
- Intelligent local fallback  
- Fail-fast error handling  
- Fully configurable script  
- Minimal dependencies  
- Structured logging  
- Predictable execution  

---

## Requirements

### Local machine

- Bash ≥ 4  
- python3  
- curl
- websocat
- VLC  

Linux is recommended.

---

### Remote device

A VLC instance capable of receiving WebSocket commands.

Examples include:

- VLC with a WebSocket bridge  
- Node-based VLC remote controller  
- Custom HTTP/WebSocket wrapper  

> The script assumes a working WebSocket endpoint.

---

## Installation

Clone the repository:

```bash
git clone https://github.com/<your-user>/hayase-vlc-bridge.git
cd hayase-vlc-bridge
```

Make the script executable:

```bash
chmod +x hayase-vlc-bridge.sh
```

Then configure it inside Hayase:

```
Settings → Player → External Player
```

Set the command to:

```
/path/to/hayase-vlc-bridge.sh
```

---

## Configuration

Only edit the **CONFIG** section at the top of the script.

The script is intentionally designed to be configured directly rather than through environment variables, ensuring predictable behavior when launched automatically by Hayase.

---

### Stream Host (IMPORTANT)

```bash
STREAM_HOST="192.168.x.x"
```

This must be reachable from the remote device.

Do NOT use:

- `localhost`  
- `127.0.0.1`  

Use your LAN IP instead.

---

### Remote VLC

```bash
REMOTE_HOST="192.168.x.x"
WS_URL="ws://${REMOTE_HOST}"
```

Example WebSocket endpoint:

```
ws://192.168.1.50:8080
```

---

### Local VLC Command

Default (Flatpak):

```bash
VLC_LOCAL=(flatpak run org.videolan.VLC --one-instance)
```

If you installed VLC natively:

```bash
VLC_LOCAL=(vlc --one-instance)
```

AppImage example:

```bash
VLC_LOCAL=(~/Applications/VLC.AppImage)
```

---

### Logging

```bash
LOG_VERBOSITY=0
```

| Value | Behavior |
|--------|------------|
| 0 | Disabled |
| 1 | Basic logs |
| 2 | Debug logs |

Log location is fully configurable:

```bash
LOG_DIR="..."
LOG_FILE="..."
```

You may freely change both the directory and filename.

---

## Execution Model

### Hard failures (script stops)

- Missing URL  
- Invalid URL  
- Parsing failure  

These typically indicate a broken stream.

---

### Soft failures (automatic fallback)

- Remote VLC unreachable  
- WebSocket failure  
- Missing `websocat`  

Local playback is considered safer than interrupting the user experience.

---

## How It Works

```
Hayase
   ↓
External Player Script
   ↓
Rewrite URL (localhost → LAN IP)
   ↓
Send to Remote VLC (WebSocket)
   ↓
Remote device plays the stream
```

Fallback path:

```
Remote unavailable → Local VLC launches automatically
```

---

## Design Principles

The project intentionally maintains a narrow scope to preserve reliability and simplicity.

It prioritizes:

- deterministic behavior  
- fail-fast execution  
- minimal moving parts  
- low operational friction  
- clear failure states  
- maintainability  

The goal is not feature bloat — it is reliability.

---

## When Should You Use This?

This bridge is particularly useful if:

- You watch Hayase on a desktop but prefer playback on a TV  
- Your remote device cannot access localhost streams  
- You want automatic playback without manual URL handling  
- You value predictable behavior over complex tooling  

---

## ![License](https://img.shields.io/badge/license-MIT-green)
