#!/usr/bin/env python3
"""
hcproxy.py - bridge between the HamClock REST API and the Roku channel.

Why it exists: HamClock's /get_capture.bmp is a top-down 16-bit RGB565 BMP (BITMAPV4HEADER),
which Roku's image decoder is unlikely to handle. This proxy fetches it, converts it to JPEG
and exposes a few simple endpoints the Roku channel uses:

    GET /frame.jpg            latest screen capture as JPEG
    GET /touch?x=N&y=N        tap; N is 0..9999 across the picture (scaled to HamClock's 800x480 app space)
    GET /info                 {"width":..,"height":..} of the HamClock screen
    GET /hc/<anything>        passed straight through to HamClock, e.g. /hc/get_time.txt

Usage:
    python3 hcproxy.py --upstream 192.168.1.20:8080          # real HamClock
    python3 hcproxy.py --mock                                # fake HamClock for testing

Requires: pip install pillow numpy
"""
import argparse
import base64
import hashlib
import io
import json
import re
import socketserver
import struct
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np
from PIL import Image, ImageDraw, ImageFont

# HamClock's touch coordinate space is ALWAYS the original 800x480 "app" size (tft.width()/height()
# return APP_WIDTH/APP_HEIGHT), even on 1600x960 / 2400x1440 / 3200x1920 builds whose screen captures
# are larger. Its own web page divides pointer coords by app_scale before sending set_touch.
APP_W, APP_H = 800, 480

# ----------------------------------------------------------------------------- BMP decode

def bmp_to_image(data: bytes) -> Image.Image:
    """Decode the BMPs HamClock produces (16-bit 565, top-down or bottom-up) plus 24/32-bit."""
    if data[:2] != b"BM":
        raise ValueError("not a BMP")
    off = struct.unpack_from("<I", data, 10)[0]
    w, h = struct.unpack_from("<ii", data, 18)
    bpp = struct.unpack_from("<H", data, 28)[0]
    top_down = h < 0
    h = abs(h)
    row_bytes = 4 * ((bpp * w + 31) // 32)
    pix = data[off:off + row_bytes * h]
    if len(pix) < row_bytes * h:
        raise ValueError("truncated BMP (%d < %d)" % (len(pix), row_bytes * h))

    if bpp == 16:
        arr = np.frombuffer(pix, dtype="<u2").reshape(h, row_bytes // 2)[:, :w]
        r = ((arr >> 11) & 0x1F).astype(np.uint16)
        g = ((arr >> 5) & 0x3F).astype(np.uint16)
        b = (arr & 0x1F).astype(np.uint16)
        rgb = np.dstack(((r * 255 + 15) // 31, (g * 255 + 31) // 63, (b * 255 + 15) // 31)).astype(np.uint8)
    elif bpp in (24, 32):
        px = bpp // 8
        arr = np.frombuffer(pix, dtype=np.uint8).reshape(h, row_bytes)[:, : w * px].reshape(h, w, px)
        rgb = arr[:, :, 2::-1].copy()      # BGR(A) -> RGB
    else:
        raise ValueError("unsupported BMP depth %d" % bpp)

    if not top_down:
        rgb = rgb[::-1]
    return Image.fromarray(rgb, "RGB")


def image_to_bmp565(img: Image.Image) -> bytes:
    """Encode exactly like HamClock's createBMP565Header(): V4 header, top-down, 565 masks."""
    img = img.convert("RGB")
    w, h = img.size
    a = np.asarray(img, dtype=np.uint16)
    v = ((a[:, :, 0] >> 3) << 11) | ((a[:, :, 1] >> 2) << 5) | (a[:, :, 2] >> 3)
    pix = v.astype("<u2").tobytes()
    hdr_len = 14 + 108
    hdr = bytearray(hdr_len)
    hdr[0:2] = b"BM"
    struct.pack_into("<IHHI", hdr, 2, hdr_len + len(pix), 0, 0, hdr_len)
    struct.pack_into("<IiiHHIIiiII", hdr, 14, 108, w, -h, 1, 16, 3, len(pix), 0, 0, 0, 0)
    struct.pack_into("<IIII", hdr, 54, 0xF800, 0x07E0, 0x001F, 0)
    struct.pack_into("<I", hdr, 70, 1)
    return bytes(hdr) + pix

# ----------------------------------------------------------------------------- mock HamClock

class MockHamClock:
    """Just enough of HamClock to exercise the channel: a changing picture and set_touch."""

    def __init__(self, w, h):
        self.w, self.h = w, h
        self.touches = 0
        self.last = None
        self.lock = threading.Lock()
        s = h / 480.0
        self.buttons = []                     # [x0,y0,x1,y1,label,on]
        labels = ["PANE 1", "PANE 2", "PANE 3", "MAP", "LOCK", "SAT"]
        for i, lab in enumerate(labels):
            x0 = int((20 + (i % 3) * 130) * s)
            y0 = int((300 + (i // 3) * 80) * s)
            self.buttons.append([x0, y0, x0 + int(120 * s), y0 + int(70 * s), lab, False])
        self.s = s

    def font(self, size):
        try:
            return ImageFont.load_default(size=max(8, int(size * self.s)))
        except TypeError:
            return ImageFont.load_default()

    def render(self) -> Image.Image:
        w, h, s = self.w, self.h, self.s
        img = Image.new("RGB", (w, h), (8, 12, 28))
        d = ImageDraw.Draw(img)
        # fake map
        mx0, my0, mx1, my1 = int(420 * s), int(150 * s), int(790 * s), int(470 * s)
        d.rectangle((mx0, my0, mx1, my1), fill=(12, 48, 90), outline=(120, 160, 200))
        for i in range(1, 12):
            x = mx0 + (mx1 - mx0) * i // 12
            d.line((x, my0, x, my1), fill=(30, 80, 130))
        for i in range(1, 6):
            y = my0 + (my1 - my0) * i // 6
            d.line((mx0, y, mx1, y), fill=(30, 80, 130))
        d.ellipse((mx0 + 80 * s, my0 + 60 * s, mx0 + 220 * s, my0 + 180 * s), fill=(40, 110, 60))
        d.ellipse((mx0 + 260 * s, my0 + 100 * s, mx0 + 400 * s, my0 + 240 * s), fill=(40, 110, 60))
        # clock
        now = time.gmtime()
        d.text((int(20 * s), int(10 * s)), "MOCK HAMCLOCK", font=self.font(28), fill=(255, 200, 0))
        d.text((int(20 * s), int(60 * s)), time.strftime("%H:%M:%S", now), font=self.font(64), fill=(255, 255, 255))
        d.text((int(20 * s), int(150 * s)), time.strftime("%Y-%m-%d UTC", now), font=self.font(24), fill=(180, 220, 255))
        with self.lock:
            n, last = self.touches, self.last
            btns = [b[:] for b in self.buttons]
        d.text((int(20 * s), int(200 * s)), "taps: %d" % n, font=self.font(28), fill=(120, 255, 120))
        d.text((int(20 * s), int(240 * s)), "last: %s" % (last if last else "-"), font=self.font(22), fill=(200, 200, 200))
        for x0, y0, x1, y1, lab, on in btns:
            d.rectangle((x0, y0, x1, y1), fill=(30, 140, 60) if on else (50, 50, 70), outline=(220, 220, 220), width=2)
            d.text((x0 + 10 * s, y0 + 20 * s), lab + (" ON" if on else ""), font=self.font(20), fill=(255, 255, 255))
        # corner markers so cropping / scaling problems are obvious
        for (cx, cy) in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)):
            d.rectangle((cx - 12, cy - 12, cx + 12, cy + 12), outline=(255, 0, 0), width=4)
        if last:
            lx, ly = self._last_xy
            d.line((lx - 15, ly, lx + 15, ly), fill=(255, 255, 0), width=3)
            d.line((lx, ly - 15, lx, ly + 15), fill=(255, 255, 0), width=3)
        return img

    _last_xy = (0, 0)

    def touch(self, x, y):
        """x,y are in 800x480 APP coordinates, like the real set_touch; convert to screen pixels."""
        sx, sy = x * self.w // APP_W, y * self.h // APP_H
        with self.lock:
            self.touches += 1
            self.last = "app %d,%d" % (x, y)
            self._last_xy = (sx, sy)
            for b in self.buttons:
                if b[0] <= sx <= b[2] and b[1] <= sy <= b[3]:
                    b[5] = not b[5]


def make_mock_handler(mock):
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"

        def log_message(self, fmt, *a):
            sys.stderr.write("[mock-hamclock] " + fmt % a + "\n")

        def reply(self, code, ctype, body):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            u = urllib.parse.urlparse(self.path)
            q = urllib.parse.parse_qs(u.query)
            if u.path == "/get_capture.bmp":
                self.reply(200, "image/bmp", image_to_bmp565(mock.render()))
            elif u.path == "/set_touch":
                try:
                    x, y = int(q["x"][0]), int(q["y"][0])
                    if not (0 <= x < APP_W and 0 <= y < APP_H):
                        raise ValueError
                except (KeyError, ValueError):
                    self.reply(400, "text/plain", ("require 0 .. x .. %d and 0 .. y .. %d\n" % (APP_W - 1, APP_H - 1)).encode())
                    return
                mock.touch(x, y)
                self.reply(200, "text/plain", ("Web touch %d %d\n" % (x, y)).encode())
            elif u.path == "/get_time.txt":
                self.reply(200, "text/plain", time.strftime("Clock_UTC %Y-%m-%dT%H:%M:%S\n", time.gmtime()).encode())
            else:
                self.reply(404, "text/plain", b"mock: unknown command\n")
    return H


# ----------------------------------------------------------------------------- mock live web socket

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def _recv_exact(sock, buf, n):
    while len(buf) < n:
        chunk = sock.recv(65536)
        if not chunk:
            raise EOFError
        buf += chunk
    return buf[:n], buf[n:]


def ws_read_frame(sock, buf):
    """Return (opcode, payload, remaining_buf) for one (client, masked) WebSocket frame."""
    hdr, buf = _recv_exact(sock, buf, 2)
    opcode, ln = hdr[0] & 0x0F, hdr[1] & 0x7F
    masked = bool(hdr[1] & 0x80)
    if ln == 126:
        ext, buf = _recv_exact(sock, buf, 2)
        ln = struct.unpack(">H", ext)[0]
    elif ln == 127:
        ext, buf = _recv_exact(sock, buf, 8)
        ln = struct.unpack(">Q", ext)[0]
    mask = b""
    if masked:
        mask, buf = _recv_exact(sock, buf, 4)
    payload, buf = _recv_exact(sock, buf, ln)
    if masked:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return opcode, payload, buf


def ws_send_frame(sock, opcode, payload=b""):
    n = len(payload)
    if n < 126:
        head = struct.pack(">BB", 0x80 | opcode, n)
    elif n < 65536:
        head = struct.pack(">BBH", 0x80 | opcode, 126, n)
    else:
        head = struct.pack(">BBQ", 0x80 | opcode, 127, n)
    sock.sendall(head + payload)


def make_live_handler(mock):
    """Speaks the subset of HamClock's live web socket protocol that the Roku channel uses:
         get_live.png?  -> one binary message holding a complete PNG of the screen
         get_live.bin?  -> incremental update (we always answer 'nothing changed')
         set_touch?x=X&y=Y&button=B  (800x480 app coordinates)"""
    class H(socketserver.BaseRequestHandler):
        def log(self, msg):
            sys.stderr.write("[mock-live] " + msg + "\n")

        def handle(self):
            sock = self.request
            sock.settimeout(120)
            data = b""
            try:
                while b"\r\n\r\n" not in data:
                    chunk = sock.recv(4096)
                    if not chunk:
                        return
                    data += chunk
                head, buf = data.split(b"\r\n\r\n", 1)
                m = re.search(r"Sec-WebSocket-Key:\s*(\S+)", head.decode("latin1"), re.I)
                if not m:
                    body = b"mock HamClock live web server\n"
                    sock.sendall(b"HTTP/1.0 200 OK\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
                    return
                accept = base64.b64encode(hashlib.sha1((m.group(1) + WS_GUID).encode()).digest()).decode()
                sock.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                              "Connection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n" % accept).encode())
                self.log("client %s connected" % self.client_address[0])
                while True:
                    opcode, payload, buf = ws_read_frame(sock, buf)
                    if opcode == 8:                                  # close
                        ws_send_frame(sock, 8, payload[:2])
                        return
                    if opcode == 9:                                  # ping
                        ws_send_frame(sock, 10, payload)
                        continue
                    if opcode != 1:
                        continue
                    cmd = payload.decode("utf-8", "replace")
                    if cmd.startswith("get_live.png?"):
                        out = io.BytesIO()
                        mock.render().save(out, "PNG")
                        ws_send_frame(sock, 2, out.getvalue())
                        self.log("get_live.png? -> %d bytes" % len(out.getvalue()))
                    elif cmd.startswith("get_live.bin?"):
                        ws_send_frame(sock, 2, b"\0\0\0\0")
                    elif cmd.startswith("set_touch?"):
                        q = urllib.parse.parse_qs(cmd[len("set_touch?"):])
                        try:
                            x, y = int(q["x"][0]), int(q["y"][0])
                            if not (0 <= x < APP_W and 0 <= y < APP_H):
                                raise ValueError
                        except (KeyError, ValueError):
                            self.log("set_touch rejected: %s" % cmd)
                            continue
                        mock.touch(x, y)
                        self.log("set_touch %d %d" % (x, y))
                    else:
                        self.log("ignoring %s" % cmd)
            except (EOFError, ConnectionError, OSError):
                return
    return H


class _ThreadedTCP(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True

# ----------------------------------------------------------------------------- proxy

class Proxy:
    def __init__(self, upstream, max_width, quality, min_interval, verbose=False):
        self.verbose = verbose
        self.upstream = upstream.rstrip("/")
        if not self.upstream.startswith("http"):
            self.upstream = "http://" + self.upstream
        self.max_width, self.quality, self.min_interval = max_width, quality, min_interval
        self.lock = threading.Lock()
        self.cache = None            # (time, jpeg bytes)
        self.size = None             # native (w, h)

    def get(self, path, timeout=8):
        with urllib.request.urlopen(self.upstream + path, timeout=timeout) as r:
            return r.read()

    def frame(self) -> bytes:
        with self.lock:                                   # one upstream fetch at a time, shared by clients
            now = time.time()
            if self.cache and now - self.cache[0] < self.min_interval:
                return self.cache[1]
            t0 = time.time()
            raw = self.get("/get_capture.bmp")
            t1 = time.time()
            img = bmp_to_image(raw)
            self.size = img.size
            if self.max_width and img.width > self.max_width:
                img = img.resize((self.max_width, img.height * self.max_width // img.width), Image.BILINEAR)
            buf = io.BytesIO()
            img.save(buf, "JPEG", quality=self.quality)
            self.cache = (time.time(), buf.getvalue())
            if self.verbose:
                t2 = time.time()
                sys.stderr.write("[hcproxy] frame: HamClock capture %.2fs (%d KB), convert %.2fs, JPEG %d KB\n"
                                 % (t1 - t0, len(raw) // 1024, t2 - t1, len(self.cache[1]) // 1024))
            return self.cache[1]

    def native_size(self):
        if not self.size:
            self.frame()
        return self.size


def make_proxy_handler(proxy):
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"

        def log_message(self, fmt, *a):
            sys.stderr.write("[hcproxy] " + fmt % a + "\n")

        def reply(self, code, ctype, body):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.cors_headers()
            self.end_headers()
            self.wfile.write(body)

        def cors_headers(self):
            # lets browser/Electron-based Roku simulators (brs-desktop, brs-emu) fetch from us.
            # Allow-Private-Network answers Chromium's "may a web page reach a LAN/localhost server?" check.
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "*")
            self.send_header("Access-Control-Allow-Private-Network", "true")

        def do_OPTIONS(self):
            self.send_response(204)
            self.cors_headers()
            self.send_header("Access-Control-Max-Age", "600")
            self.end_headers()

        def do_GET(self):
            u = urllib.parse.urlparse(self.path)
            q = urllib.parse.parse_qs(u.query)
            try:
                if u.path == "/frame.jpg":
                    self.reply(200, "image/jpeg", proxy.frame())
                elif u.path == "/touch":
                    fx = min(max(int(q["x"][0]), 0), 9999)
                    fy = min(max(int(q["y"][0]), 0), 9999)
                    x, y = fx * APP_W // 10000, fy * APP_H // 10000
                    body = proxy.get("/set_touch?x=%d&y=%d" % (x, y))
                    self.reply(200, "text/plain", body)
                elif u.path == "/info":
                    w, h = proxy.native_size()
                    self.reply(200, "application/json", json.dumps({"width": w, "height": h}).encode())
                elif u.path.startswith("/hc/"):
                    rest = u.path[3:] + (("?" + u.query) if u.query else "")
                    self.reply(200, "text/plain", proxy.get(rest))
                elif u.path == "/":
                    self.reply(200, "text/plain", b"hcproxy ok. try /frame.jpg /info /touch?x=5000&y=5000\n")
                else:
                    self.reply(404, "text/plain", b"not found\n")
            except (KeyError, ValueError) as e:
                self.reply(400, "text/plain", ("bad request: %s\n" % e).encode())
            except urllib.error.HTTPError as e:
                self.reply(502, "text/plain", ("upstream HTTP %d\n" % e.code).encode())
            except Exception as e:
                self.reply(502, "text/plain", ("upstream error: %s\n" % e).encode())
    return H

# ----------------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--upstream", default="localhost:8080", help="HamClock REST host:port (default localhost:8080)")
    ap.add_argument("--mock", action="store_true", help="run a fake HamClock instead of using --upstream")
    ap.add_argument("--mock-port", type=int, default=8080)
    ap.add_argument("--mock-live-port", type=int, default=8081, help="port for the mock live web socket")
    ap.add_argument("--mock-size", default="800x480", help="mock screen size, e.g. 800x480 or 1600x960")
    ap.add_argument("--port", type=int, default=8090, help="port the Roku connects to (default 8090)")
    ap.add_argument("--max-width", type=int, default=1280, help="downscale frames wider than this (0 = never)")
    ap.add_argument("--quality", type=int, default=80, help="JPEG quality")
    ap.add_argument("--verbose", action="store_true", help="log how long each HamClock capture and conversion takes")
    ap.add_argument("--min-interval", type=float, default=0.4, help="min seconds between upstream captures")
    a = ap.parse_args()

    upstream = a.upstream
    if a.mock:
        mw, mh = (int(v) for v in a.mock_size.lower().split("x"))
        mock = MockHamClock(mw, mh)
        srv = ThreadingHTTPServer(("127.0.0.1", a.mock_port), make_mock_handler(mock))
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        live = _ThreadedTCP(("0.0.0.0", a.mock_live_port), make_live_handler(mock))
        threading.Thread(target=live.serve_forever, daemon=True).start()
        upstream = "127.0.0.1:%d" % a.mock_port
        print("mock HamClock %dx%d: REST on 127.0.0.1:%d, live web socket on 0.0.0.0:%d"
              % (mw, mh, a.mock_port, a.mock_live_port))

    proxy = Proxy(upstream, a.max_width, a.quality, a.min_interval, a.verbose)
    httpd = ThreadingHTTPServer(("0.0.0.0", a.port), make_proxy_handler(proxy))
    print("hcproxy listening on 0.0.0.0:%d  ->  %s" % (a.port, proxy.upstream))
    print("Roku address to enter:  <this-machine-ip>:%d" % a.port)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print()

if __name__ == "__main__":
    main()
