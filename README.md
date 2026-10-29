# capture-stream

Play a console (or watch any HDMI source) from another room with as little delay as possible.
An HDMI capture card plugged into a Linux box streams to a native Mac app over your home network.

```
console ──HDMI──▶ USB capture card ──▶ Linux server ──LAN (UDP)──▶ Mac app
                                       capture-streamd             Capture Stream.app
```

Your controller stays connected to the console as usual; only picture and sound travel to the Mac.

## Why another streaming tool?

Game streaming hosts (Sunshine/Moonlight, Steam Link…) expect a computer running the game. With a
capture card they end up decoding the card's video, drawing it on a screen, grabbing that screen and
encoding it again. Every step adds delay and timing jitter.

Cheap USB capture cards already send compressed **MJPEG** frames. capture-stream forwards those
frames **unchanged** and decodes them only once, on the Mac, with the hardware JPEG decoder:

- **No re-encoding** on the server: about 30% of one CPU core on an old i5.
- **No playback clock**: each frame is shown the moment it's decoded, so delay can't build up.
- **Whole frames only**: a frame with a lost packet is dropped, never shown half-broken.
- **Bounded audio buffer**: raw PCM with a jitter buffer of about 20 ms; if it ever holds more than
  60 ms it skips ahead, so sound stays in sync with the picture.
- **Live stats** (press `S`): fps, Mbps, dropped frames, video and audio delay.

Measured on a 2017 i5 server and an Apple Silicon MacBook over 5 GHz Wi-Fi, 720p60:

| | delay |
|---|---|
| video, server reads frame → decoded on Mac | ~12 ms |
| audio, server reads samples → out of the Mac's speakers | ~35–50 ms |
| frames dropped | 0 |

These figures don't include the capture card's own delay (typically 1–3 frames) or the display.

The trade-off is bandwidth. MJPEG is compressed frame by frame, so the rate depends on what's on screen:

| mode | measured | notes |
|---|---|---|
| 720p60 | 35–55 Mbps | the smoothest choice on most USB 2.0 cards |
| 1080p30 | 45–60 Mbps | sharper, half the motion smoothness |
| 1080p60 | 70–145 Mbps (~100 average) | sharpest; USB 2.0 cards may deliver a bit under 60 fps |

A wired server and a good 5 GHz connection on the Mac are recommended, especially for 1080p60.

## Requirements

**Server:** Linux with systemd, Python 3.11+, ffmpeg (with v4l2 and PulseAudio input), PipeWire or
PulseAudio, and a UVC capture card that outputs MJPEG.

**Client:** macOS 14 or later on Apple Silicon, with Swift / Xcode command-line tools to build.

## Server setup

1. Install ffmpeg (`sudo apt install ffmpeg` on Debian/Ubuntu) and check the card:
   ```bash
   v4l2-ctl --list-devices                    # find the card, e.g. /dev/video0
   v4l2-ctl -d /dev/video0 --list-formats-ext # MJPEG sizes and frame rates
   pactl list short sources                   # the card's audio input
   ```
2. Install the service (no root needed):
   ```bash
   cd server && ./install.sh
   ```
3. Edit `~/.config/capture-stream/config.toml`: set `video_device`, `audio_source` and the modes your
   card supports, then `systemctl --user restart capture-streamd`.
4. To keep it running while you're logged out: `sudo loginctl enable-linger $USER`.

Logs: `journalctl --user -u capture-streamd -f`

### Config

| key | default | meaning |
|---|---|---|
| `listen`, `control_port` | `0.0.0.0`, `47100` | where the app connects (TCP) |
| `video_device` | `/dev/video0` | V4L2 capture device |
| `audio_source` | `default` | PulseAudio/PipeWire source name |
| `default_mode` | `720p60` | mode used if the app doesn't pick one |
| `pre_start`, `post_stop` | empty | shell commands run before streaming starts / after it stops, e.g. to free the card from another program |
| `[modes.NAME]` | `720p60`, `1080p30`, `1080p60` | `width`, `height`, `fps` offered to the app |

## Client

```bash
cd client && ./make-app.sh
open "build/Capture Stream.app"
```

Enter the server's hostname or IP, pick a mode and press **Connect**. On first use macOS asks to allow
local-network access and, if the firewall is on, incoming connections. Allow both.

| key | action |
|---|---|
| `⌘F` / double-click | full screen |
| `Esc` | leave full screen |
| `S` | stats overlay |
| `⌘D` | disconnect |

Command-line options: `--connect <host> [--mode 720p60]` connects on launch, and `--log-stats` prints
the stats line every second.

The app listens on UDP ports 47101 (video) and 47102 (audio).

## Troubleshooting

- **Black screen / "no frames from the capture card"**: is the source on? Consoles with HDCP enabled
  (e.g. PS4: *Settings → System → Enable HDCP*) send nothing a capture card can record. Cheap cards
  also sometimes freeze after a mode change; unplug and replug the card's USB cable.
- **1080p60 runs below 60 fps or drops frames**: many USB 2.0 cards (MacroSilicon MS2109 and similar)
  deliver ~57 fps at 1080p60, and it needs about twice the bandwidth of 1080p30. 720p60 is usually the
  smoothest true-60 mode. `lsusb -t` showing `480M` means USB 2.0.
- **Dropped frames on Wi-Fi**: the stats overlay shows them. Move closer to the access point, use
  5 GHz, or pick a lower mode.
- **Check a server without the Mac app**: `python3 tools/probe.py <server>` connects, receives for 10 s
  and reports frames, losses and delay.

## How it works

- **Control:** TCP, one JSON object per line. The app sends `hello` (mode, UDP ports) and `ping`
  every second; the server answers `ok`, `pong` (used for clock offset) and `error`. The server stops
  streaming when the connection closes or pings stop for 3 s.
- **Video:** the server runs ffmpeg with `-c:v copy` to read the card's JPEGs. It splits them into
  ≤1400-byte UDP packets with a 20-byte header (frame id, packet index/count, capture time).
- **Audio:** the same ffmpeg sends 48 kHz stereo 16-bit PCM in 5 ms UDP packets with a 16-byte header
  (sequence number, capture time).

See the header of [`server/capture-streamd.py`](server/capture-streamd.py) for the exact layout.

## License

[MIT](LICENSE)
