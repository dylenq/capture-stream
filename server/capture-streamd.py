#!/usr/bin/env python3
"""capture-streamd: stream a UVC HDMI capture card to a capture-stream client with minimal delay.

The card's MJPEG frames are forwarded unchanged (no re-encode); audio is sent as raw PCM.
A client connects over TCP, says which mode and UDP ports it wants, and keeps pinging;
streaming stops as soon as it disconnects or goes quiet.

Wire format (all integers big-endian):
  control  TCP, one JSON object per line, both directions
  video    UDP packets: "CV" ver flags frame_id:u32 index:u16 count:u16 capture_us:u64 + JPEG slice
  audio    UDP packets: "CA" ver flags seq:u32 capture_us:u64 + 5 ms of s16le 48 kHz stereo PCM

Python 3.11+, standard library only. Needs ffmpeg with v4l2 and pulse input.
"""
import argparse
import asyncio
import json
import logging
import os
import signal
import socket
import struct
import subprocess
import threading
import time
import tomllib
from pathlib import Path

PROTOCOL_VERSION = 1
VIDEO_HEADER = struct.Struct("!2sBBIHHQ")  # 20 bytes
AUDIO_HEADER = struct.Struct("!2sBBIQ")  # 16 bytes
MAX_DATAGRAM = 1400
VIDEO_PAYLOAD = MAX_DATAGRAM - VIDEO_HEADER.size
AUDIO_CHUNK = 960  # 5 ms of 48 kHz stereo s16le
AUDIO_CHUNK_SECONDS = 0.005
PING_TIMEOUT = 3.0
NO_FRAMES_TIMEOUT = 4.0
SOI = b"\xff\xd8\xff"
EOI = b"\xff\xd9"

DEFAULT_CONFIG = {
    "listen": "0.0.0.0",
    "control_port": 47100,
    "video_device": "/dev/video0",
    "audio_source": "default",
    "default_mode": "720p60",
    "pre_start": "",
    "post_stop": "",
    "modes": {
        "720p60": {"width": 1280, "height": 720, "fps": 60},
        "1080p30": {"width": 1920, "height": 1080, "fps": 30},
        "1080p60": {"width": 1920, "height": 1080, "fps": 60},
    },
}

log = logging.getLogger("capture-streamd")


def load_config(path):
    config = dict(DEFAULT_CONFIG)
    if path and Path(path).exists():
        with open(path, "rb") as f:
            config.update(tomllib.load(f))
        log.info("loaded config %s", path)
    else:
        log.info("no config at %s, using defaults", path)
    return config


def now_us():
    return int(time.time() * 1_000_000)


class Streamer:
    """One streaming session: an ffmpeg process plus a sender thread per stream."""

    def __init__(self, config, mode, client_ip, video_port, audio_port):
        self.config = config
        self.mode = mode
        self.video_addr = (client_ip, video_port)
        self.audio_addr = (client_ip, audio_port)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 * 1024 * 1024)
        self.proc = None
        self.threads = []
        self.stopping = threading.Event()
        self.frames_sent = 0
        self.last_frame_time = 0.0
        self.started_at = time.monotonic()

    def start(self):
        m = self.mode
        audio_r, audio_w = os.pipe()
        cmd = [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin",
            "-fflags", "nobuffer", "-thread_queue_size", "32",
            "-f", "v4l2", "-input_format", "mjpeg",
            "-video_size", f"{m['width']}x{m['height']}", "-framerate", str(m["fps"]),
            "-i", self.config["video_device"],
            "-thread_queue_size", "64", "-f", "pulse", "-fragment_size", str(AUDIO_CHUNK),
            "-i", self.config["audio_source"],
            "-map", "0:v", "-c:v", "copy", "-flush_packets", "1", "-f", "mjpeg", "pipe:1",
            "-map", "1:a", "-c:a", "pcm_s16le", "-ar", "48000", "-ac", "2",
            "-flush_packets", "1", "-f", "s16le", f"pipe:{audio_w}",
        ]
        log.info("starting ffmpeg: %s", " ".join(cmd))
        self.proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, pass_fds=(audio_w,), start_new_session=True
        )
        os.close(audio_w)
        self.threads = [
            threading.Thread(target=self._video_loop, args=(self.proc.stdout.fileno(),), daemon=True),
            threading.Thread(target=self._audio_loop, args=(audio_r,), daemon=True),
        ]
        for t in self.threads:
            t.start()

    def stop(self):
        self.stopping.set()
        if self.proc and self.proc.poll() is None:
            os.killpg(self.proc.pid, signal.SIGTERM)
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(self.proc.pid, signal.SIGKILL)
                self.proc.wait()
        for t in self.threads:
            t.join(timeout=2)
        self.sock.close()
        log.info("stopped after %d frames", self.frames_sent)

    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    def _send_frame(self, frame_id, frame):
        captured = now_us()
        count = (len(frame) + VIDEO_PAYLOAD - 1) // VIDEO_PAYLOAD
        for index in range(count):
            payload = frame[index * VIDEO_PAYLOAD:(index + 1) * VIDEO_PAYLOAD]
            header = VIDEO_HEADER.pack(b"CV", PROTOCOL_VERSION, 0, frame_id, index, count, captured)
            try:
                self.sock.sendto(header + payload, self.video_addr)
            except OSError as e:
                log.warning("video send failed: %s", e)
                return
        self.frames_sent += 1
        self.last_frame_time = time.monotonic()

    def _video_loop(self, fd):
        # ffmpeg writes the card's JPEGs back to back. A frame ends at its EOI marker, which
        # can't occur inside JPEG data; some cards omit it, so the next SOI also ends a frame.
        buf = bytearray()
        frame_id = 0
        while not self.stopping.is_set():
            chunk = os.read(fd, 262144)
            if not chunk:
                break
            buf += chunk
            while True:
                start = buf.find(SOI)
                if start < 0:
                    del buf[:max(0, len(buf) - 2)]
                    break
                if start:
                    del buf[:start]
                end = buf.find(EOI, 3)
                next_start = buf.find(SOI, 3)
                if end >= 0 and (next_start < 0 or end < next_start):
                    frame_end = end + 2
                elif next_start >= 0:
                    frame_end = next_start
                else:
                    break
                frame_id = (frame_id + 1) & 0xFFFFFFFF
                self._send_frame(frame_id, bytes(buf[:frame_end]))
                del buf[:frame_end]
        log.info("video stream ended")

    def _audio_loop(self, fd):
        buf = bytearray()
        seq = 0
        while not self.stopping.is_set():
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            buf += chunk
            read_at = now_us()
            chunks = len(buf) // AUDIO_CHUNK
            for i in range(chunks):
                # the newest chunk was captured ~5 ms before it was read; older ones earlier still
                captured = read_at - int((chunks - i) * AUDIO_CHUNK_SECONDS * 1_000_000)
                seq = (seq + 1) & 0xFFFFFFFF
                header = AUDIO_HEADER.pack(b"CA", PROTOCOL_VERSION, 0, seq, captured)
                try:
                    self.sock.sendto(header + bytes(buf[i * AUDIO_CHUNK:(i + 1) * AUDIO_CHUNK]), self.audio_addr)
                except OSError as e:
                    log.warning("audio send failed: %s", e)
            del buf[:chunks * AUDIO_CHUNK]
        os.close(fd)
        log.info("audio stream ended")


class Server:
    def __init__(self, config):
        self.config = config
        self.session = None  # (writer, Streamer)
        self.lock = asyncio.Lock()

    async def run_hook(self, name):
        command = self.config.get(name) or ""
        if not command:
            return
        log.info("running %s hook", name)
        proc = await asyncio.create_subprocess_shell(command)
        try:
            await asyncio.wait_for(proc.wait(), timeout=15)
        except asyncio.TimeoutError:
            proc.kill()
            log.warning("%s hook timed out", name)

    async def stop_session(self, owner=None, replaced_by=None):
        """Stop the current session; with owner, only if that client owns it.
        With replaced_by, tell the previous owner (if it's someone else) why it stopped."""
        async with self.lock:
            if self.session is None or (owner is not None and self.session[0] is not owner):
                return
            old_writer, streamer = self.session
            self.session = None
        await asyncio.to_thread(streamer.stop)
        await self.run_hook("post_stop")
        if replaced_by is not None and old_writer is not replaced_by:
            try:
                await send(old_writer, {"type": "stopped", "reason": "another client connected"})
            except ConnectionError:
                pass

    async def handle(self, reader, writer):
        peer_ip = writer.get_extra_info("peername")[0]
        log.info("client connected from %s", peer_ip)
        try:
            await self.serve_client(reader, writer, peer_ip)
        except (ConnectionError, asyncio.IncompleteReadError):
            pass
        finally:
            await self.stop_session(owner=writer)
            writer.close()
            log.info("client %s gone", peer_ip)

    async def serve_client(self, reader, writer, peer_ip):
        while True:
            try:
                line = await asyncio.wait_for(reader.readline(), timeout=PING_TIMEOUT)
            except asyncio.TimeoutError:
                log.info("client %s stopped pinging", peer_ip)
                return
            if not line:
                return
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            kind = msg.get("type")
            if kind == "ping":
                await send(writer, {"type": "pong", "t": msg.get("t"), "server_t": time.time()})
                await self.check_frames(writer)
            elif kind == "hello":
                await self.start_session(writer, peer_ip, msg)
            elif kind == "bye":
                return

    async def start_session(self, writer, peer_ip, msg):
        modes = self.config["modes"]
        mode_name = msg.get("mode") or self.config["default_mode"]
        if mode_name not in modes:
            await send(writer, {"type": "error", "message": f"unknown mode {mode_name}", "modes": list(modes)})
            return
        await self.stop_session(replaced_by=writer)
        await self.run_hook("pre_start")
        streamer = Streamer(self.config, modes[mode_name], peer_ip,
                            int(msg.get("video_port", 47101)), int(msg.get("audio_port", 47102)))
        await asyncio.to_thread(streamer.start)
        async with self.lock:
            self.session = (writer, streamer)
        mode = modes[mode_name]
        log.info("streaming %s to %s", mode_name, peer_ip)
        await send(writer, {"type": "ok", "mode": mode_name, "modes": list(modes), **mode})

    async def check_frames(self, writer):
        # A frozen card opens fine but delivers nothing; tell the client instead of hanging.
        if self.session is None or self.session[0] is not writer:
            return
        streamer = self.session[1]
        quiet = time.monotonic() - max(streamer.last_frame_time, streamer.started_at)
        if not streamer.alive():
            await send(writer, {"type": "error", "message": "ffmpeg exited; check the server log"})
        elif quiet > NO_FRAMES_TIMEOUT:
            await send(writer, {"type": "error", "message":
                                "no frames from the capture card; check the source or replug the card"})


async def send(writer, obj):
    writer.write(json.dumps(obj).encode() + b"\n")
    await writer.drain()


async def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--config", default=os.path.expanduser("~/.config/capture-stream/config.toml"))
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    config = load_config(args.config)
    server = Server(config)
    tcp = await asyncio.start_server(server.handle, config["listen"], config["control_port"])
    log.info("listening on %s:%d", config["listen"], config["control_port"])
    async with tcp:
        await tcp.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
