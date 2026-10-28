#!/usr/bin/env python3
"""Connect to capture-streamd like the app does, receive for a while, and report what arrived.

  python3 tools/probe.py <server-host> [--mode 720p60] [--seconds 10] [--save-frame frame.jpg]

Reports complete/incomplete video frames, frame rate, bitrate, audio packet gaps, and the
capture-to-receive delay (using the ping/pong clock offset). Useful for checking a server
without the Mac app.
"""
import argparse
import json
import socket
import statistics
import struct
import threading
import time

VIDEO_HEADER = struct.Struct("!2sBBIHHQ")
AUDIO_HEADER = struct.Struct("!2sBBIQ")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("host")
    p.add_argument("--port", type=int, default=47100)
    p.add_argument("--mode")
    p.add_argument("--seconds", type=float, default=10)
    p.add_argument("--video-port", type=int, default=47101)
    p.add_argument("--audio-port", type=int, default=47102)
    p.add_argument("--save-frame")
    a = p.parse_args()

    vsock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    vsock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
    vsock.bind(("", a.video_port))
    asock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    asock.bind(("", a.audio_port))
    for s in (vsock, asock):
        s.settimeout(0.5)

    ctrl = socket.create_connection((a.host, a.port), timeout=5)
    ctrl_file = ctrl.makefile("rwb")

    def send(obj):
        ctrl_file.write(json.dumps(obj).encode() + b"\n")
        ctrl_file.flush()

    offsets, messages = [], []
    send({"type": "hello", "mode": a.mode, "video_port": a.video_port, "audio_port": a.audio_port})

    def control_reader():
        for line in ctrl_file:
            msg = json.loads(line)
            if msg["type"] == "pong":
                t1 = time.time()
                rtt = t1 - msg["t"]
                offsets.append((rtt, msg["server_t"] - (msg["t"] + t1) / 2))
            else:
                messages.append(msg)

    threading.Thread(target=control_reader, daemon=True).start()
    stop = time.monotonic() + a.seconds

    frames = {}  # frame_id -> [count, received, bytes, capture_us, first_seen]
    complete, video_bytes, video_delays = [], 0, []
    saved = False
    audio_seqs, audio_delays = [], []

    def recv_audio():
        while time.monotonic() < stop:
            try:
                data = asock.recv(2048)
            except socket.timeout:
                continue
            magic, _, _, seq, cap = AUDIO_HEADER.unpack_from(data)
            if magic == b"CA":
                audio_seqs.append(seq)
                audio_delays.append((time.time(), cap))

    threading.Thread(target=recv_audio, daemon=True).start()
    next_ping = 0
    while time.monotonic() < stop:
        if time.monotonic() >= next_ping:
            send({"type": "ping", "t": time.time()})
            next_ping = time.monotonic() + 1
        try:
            data = vsock.recv(2048)
        except socket.timeout:
            continue
        magic, _, _, fid, idx, count, cap = VIDEO_HEADER.unpack_from(data)
        if magic != b"CV":
            continue
        video_bytes += len(data)
        f = frames.setdefault(fid, [count, {}, cap])
        f[1][idx] = data[VIDEO_HEADER.size:]
        if len(f[1]) == count:
            complete.append(fid)
            video_delays.append((time.time(), cap))
            if a.save_frame and not saved:
                with open(a.save_frame, "wb") as out:
                    out.write(b"".join(f[1][i] for i in range(count)))
                saved = True
            del frames[fid]
    send({"type": "bye"})
    ctrl.close()

    offset = min(offsets)[1] if offsets else 0.0
    to_ms = lambda pairs: [((t + offset) - c / 1e6) * 1000 for t, c in pairs[30:]]
    seen = (max(complete) - min(complete) + 1) if complete else 0
    gaps = sum(1 for x, y in zip(audio_seqs, audio_seqs[1:]) if y != x + 1)
    print(f"messages: {messages}")
    print(f"clock offset (server - here): {offset * 1000:.1f} ms, best rtt {min(offsets)[0] * 1000:.1f} ms" if offsets else "no pongs")
    print(f"video: {len(complete)} complete frames, {seen - len(complete)} incomplete, "
          f"{len(complete) / a.seconds:.1f} fps, {video_bytes * 8 / a.seconds / 1e6:.1f} Mbps")
    for name, pairs in (("video", video_delays), ("audio", audio_delays)):
        d = sorted(to_ms(pairs))
        if d:
            print(f"{name} capture->receive delay: median {statistics.median(d):.1f} ms, "
                  f"p90 {d[int(len(d) * 0.9)]:.1f} ms")
    print(f"audio: {len(audio_seqs)} packets ({len(audio_seqs) * 0.005:.1f} s of sound), {gaps} gaps")


if __name__ == "__main__":
    main()
