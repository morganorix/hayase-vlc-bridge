# hayase-vlc-bridge
Configurable bridge that sends Hayase Watch streams to a remote VLC player, featuring automatic local fallback, fail-fast behavior, and clear logging for dependable external playback.

The goal is simple:

👉 When you click *Play* in Hayase, the script intercepts the streaming URL and sends it to a remote VLC instance via WebSocket.

If the remote player is unavailable, playback automatically falls back to your local VLC.

---

## Concept

Hayase typically streams content through a local HTTP server (`localhost`).  
An Apple TV — or any remote device — cannot access that address directly.

This script solves that by:

1. Receiving the stream URL from Hayase.
2. Rewriting `localhost` to an IP reachable by the remote device.
3. Normalizing the URL encoding.
4. Sending the stream to remote VLC through WebSocket.
5. Falling back to local VLC if anything fails.

### Execution Flow

```
Hayase
   ↓
External Player Script
   ↓
Rewrite URL (localhost → LAN IP)
   ↓
Send to Remote VLC (WebSocket)
   ↓
Apple TV plays the stream
```

Fallback path:

```
Remote unavailable → Local VLC launches automatically
```

---

## Requirements

### Local machine

- Bash (Linux recommended)
- `python3`
- `curl`
- VLC (Flatpak version in the default config)

---

### Remote device

You need a VLC instance capable of receiving WebSocket commands.

Common setups include:

- VLC with a WebSocket bridge
- Node-based VLC remote controller
- Custom VLC HTTP/WebSocket wrapper

*(The script assumes a WebSocket endpoint exists.)*

---

## Configuration

Only modify the **CONFIG** section at the top of the script.

```bash
# Logging level
LOG_VERBOSITY=0
```

| Value | Behavior |
|--------|------------|
| 0 | No file logs |
| 1 | Basic logs |
| 2 | Detailed debug logs |

---

### Paths

```bash
LOG_DIR="${HOME}/.local/logs"
LOG_FILE="${LOG_DIR}/hayase-vlc-appletv.log"
```

Where logs will be stored.

---

### Remote VLC

```bash
REMOTE_HOST="ssalon.local"
WS_URL="ws://${REMOTE_HOST}"
```

- `REMOTE_HOST` → hostname or IP of the remote VLC server.
- `WS_URL` → WebSocket endpoint.

Example:

```
ws://192.168.1.50:8080
```

---

### Stream Host (VERY IMPORTANT)

```bash
STREAM_HOST="192.168.2.68"
```

This must be the IP address reachable **from the Apple TV**.

Do NOT use:

- `localhost`
- `127.0.0.1`

Use your LAN IP instead.

---

### Local VLC Command

```bash
VLC_LOCAL=(flatpak run org.videolan.VLC --one-instance)
```

Examples:

Standard VLC:

```bash
VLC_LOCAL=(vlc)
```

AppImage:

```bash
VLC_LOCAL=(~/Applications/VLC.AppImage)
```

---

## Integrating with Hayase

Open:

```
Settings → Player → External Player
```

Set the command to your script:

```
/path/to/script.sh
```

Make it executable first:

```bash
chmod +x script.sh
```

Now when you press **Play** inside Hayase:

✅ The script receives the URL  
✅ Sends it to remote VLC  
✅ Apple TV starts playing  

No additional interaction required.

---

## Behavior Philosophy

This script follows a strict execution model:

### Hard failures (script stops)

- No URL received
- Invalid URL
- Parsing failure

These indicate a broken stream.

---

### Soft failures (fallback triggered)

- Remote VLC unreachable  
- WebSocket failure  
- `websocat` missing  

Local playback is considered safer than interrupting the user.

---

## Logging

Logs are written only if enabled.

Example:

```
~/.local/logs/hayase-vlc-appletv.log
```

Useful for diagnosing:

- Network issues
- WebSocket errors
- URL rewriting problems

---

## Why This Exists

Streaming torrents to an Apple TV is often frustrating because:

- Hayase streams locally
- Apple TV cannot access localhost
- Many remote player solutions are unreliable

This script focuses on:

✔ deterministic behavior  
✔ minimal dependencies  
✔ clear failure handling  
✔ zero UI friction  

---

## Possible Improvements

Ideas if you want to extend it:

- mDNS auto-discovery of the remote host  
- Multiple remote players  
- Retry logic before fallback  
- Native Swift bridge for tvOS  
- Dockerized VLC WebSocket server  

---

## License

MIT — do whatever you want with it.
