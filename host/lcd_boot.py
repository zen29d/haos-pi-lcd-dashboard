#!/usr/bin/env python3
"""Early boot / final shutdown screen for the Pi LCD Dashboard, run on the HAOS host.

Started by a udev rule (see 99-lcd-boot.rules) as the transient unit `lcd-boot`:
  lcd_boot.py boot   draw the boot screen and animate it until the app takes over
  lcd_boot.py stop   (ExecStop at shutdown) draw "Restarting" / "Safe to unplug"

Uses only the Python standard library. Artwork is pre-rendered by the app into
its /data/boot folder, so this script only streams raw RGB565 and fills the bar.
"""

import os
import sys
import glob
import json
import time
import fcntl
import socket
import struct
import ctypes
import subprocess

def find_boot_dir():
    """The app's /data/boot on the host, whatever slug it was installed under."""
    candidates = glob.glob("/mnt/data/supervisor/*/data/*pi_lcd_dashboard/boot/meta.json")
    if not candidates:
        return None
    return os.path.dirname(max(candidates, key=os.path.getmtime))


BOOT_DIR = find_boot_dir()
SPI_DEVICE = "/dev/spidev0.0"
CHIP = "/dev/gpiochip0"
DC, RST, BL = 25, 27, 18
if BOOT_DIR:                               # follow the app's pin options
    try:
        with open(os.path.join(BOOT_DIR, "meta.json")) as _f:
            _meta = json.load(_f)
        DC, RST, BL = _meta["pins"]["dc"], _meta["pins"]["rst"], _meta["pins"]["bl"]
        SPI_DEVICE, CHIP = _meta["spi"], _meta["chip"]
    except (OSError, ValueError, KeyError):
        pass
SPI_SPEED = 10_000_000
W, H = 320, 172
X_OFFSET, Y_OFFSET = 0, 34
TIMEOUT = 300


def log(msg):
    print(f"lcd_boot: {msg}", flush=True)


# --- GPIO character device (uAPI v2) --------------------------------------
class LineAttribute(ctypes.Structure):
    _fields_ = [("id", ctypes.c_uint32), ("padding", ctypes.c_uint32),
                ("values", ctypes.c_uint64)]


class LineConfigAttribute(ctypes.Structure):
    _fields_ = [("attr", LineAttribute), ("mask", ctypes.c_uint64)]


class LineConfig(ctypes.Structure):
    _fields_ = [("flags", ctypes.c_uint64), ("num_attrs", ctypes.c_uint32),
                ("padding", ctypes.c_uint32 * 5),
                ("attrs", LineConfigAttribute * 10)]


class LineRequest(ctypes.Structure):
    _fields_ = [("offsets", ctypes.c_uint32 * 64), ("consumer", ctypes.c_char * 32),
                ("config", LineConfig), ("num_lines", ctypes.c_uint32),
                ("event_buffer_size", ctypes.c_uint32),
                ("padding", ctypes.c_uint32 * 5), ("fd", ctypes.c_int32)]


class LineValues(ctypes.Structure):
    _fields_ = [("bits", ctypes.c_uint64), ("mask", ctypes.c_uint64)]


def _iowr(nr, size):
    return (3 << 30) | (size << 16) | (0xB4 << 8) | nr


GPIO_V2_GET_LINE_IOCTL = _iowr(0x07, ctypes.sizeof(LineRequest))
GPIO_V2_LINE_SET_VALUES_IOCTL = _iowr(0x0F, ctypes.sizeof(LineValues))
GPIO_V2_LINE_FLAG_OUTPUT = 1 << 3
GPIO_V2_LINE_ATTR_ID_OUTPUT_VALUES = 2
LINES = (DC, RST, BL)


class Gpio:
    def __init__(self, initial):
        req = LineRequest()
        for i, line in enumerate(LINES):
            req.offsets[i] = line
        req.num_lines = len(LINES)
        req.consumer = b"lcd-boot"
        req.config.flags = GPIO_V2_LINE_FLAG_OUTPUT
        req.config.num_attrs = 1
        req.config.attrs[0].attr.id = GPIO_V2_LINE_ATTR_ID_OUTPUT_VALUES
        req.config.attrs[0].attr.values = self._bits(initial)
        req.config.attrs[0].mask = (1 << len(LINES)) - 1
        with open(CHIP, "rb") as chip:
            fcntl.ioctl(chip.fileno(), GPIO_V2_GET_LINE_IOCTL, req)  # EBUSY if app owns it
        self.fd = req.fd
        self.values = dict(initial)

    @staticmethod
    def _bits(values):
        return sum(1 << i for i, line in enumerate(LINES) if values.get(line))

    def set(self, line, value):
        self.values[line] = value
        v = LineValues(self._bits(self.values), 1 << LINES.index(line))
        fcntl.ioctl(self.fd, GPIO_V2_LINE_SET_VALUES_IOCTL, v)

    def close(self):
        os.close(self.fd)


# --- ST7789 ---------------------------------------------------------------
class Panel:
    def __init__(self, gpio):
        self.gpio = gpio
        self.spi = open(SPI_DEVICE, "wb", buffering=0)
        fd = self.spi.fileno()
        fcntl.ioctl(fd, 0x40016b01, struct.pack("B", 0))
        fcntl.ioctl(fd, 0x40016b03, struct.pack("B", 8))
        fcntl.ioctl(fd, 0x40046b04, struct.pack("I", SPI_SPEED))

    def command(self, cmd, data=None):
        self.gpio.set(DC, 0)
        self.spi.write(bytes([cmd]))
        if data:
            self.gpio.set(DC, 1)
            self.spi.write(bytes(data))

    def init(self):
        self.command(0x11)                 # Sleep out
        time.sleep(0.12)
        self.command(0x3A, [0x55])         # RGB565
        self.command(0x36, [0x70])         # Landscape orientation
        self.command(0x21)                 # Inversion on
        self.command(0x13)                 # Normal display mode
        self.command(0x29)                 # Display on

    def blit(self, x0, y0, x1, y1, data):
        """Write RGB565 data to the inclusive rectangle (x0, y0)-(x1, y1)."""
        x0, x1, y0, y1 = x0 + X_OFFSET, x1 + X_OFFSET, y0 + Y_OFFSET, y1 + Y_OFFSET
        self.command(0x2A, [x0 >> 8, x0 & 255, x1 >> 8, x1 & 255])
        self.command(0x2B, [y0 >> 8, y0 & 255, y1 >> 8, y1 & 255])
        self.command(0x2C)
        self.gpio.set(DC, 1)
        for i in range(0, len(data), 4096):
            self.spi.write(data[i:i + 4096])

    def fill(self, x0, y0, x1, y1, color):
        n = (x1 - x0 + 1) * (y1 - y0 + 1)
        self.blit(x0, y0, x1, y1, struct.pack(">H", color) * n)

    def close(self):
        self.spi.close()


def asset(name):
    with open(os.path.join(BOOT_DIR, name), "rb") as f:
        return f.read()


def load_meta():
    with open(os.path.join(BOOT_DIR, "meta.json")) as f:
        return json.load(f)


# --- Boot progress --------------------------------------------------------
def supervisor_running():
    """Ask the Docker API whether the hassio_supervisor container is running."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(1)
            s.connect("/run/docker.sock")
            s.sendall(b"GET /containers/hassio_supervisor/json HTTP/1.0\r\n"
                      b"Host: docker\r\n\r\n")
            data = b""
            while chunk := s.recv(65536):
                data += chunk
        body = data.split(b"\r\n\r\n", 1)[1]
        return json.loads(body)["State"]["Running"]
    except (OSError, ValueError, KeyError, IndexError):
        return False


def boot():
    meta = load_meta()
    takeover = os.path.join(BOOT_DIR, "takeover")
    try:
        os.remove(takeover)
    except OSError:
        pass

    gpio = Gpio({DC: 0, RST: 0, BL: 0})
    panel = Panel(gpio)
    time.sleep(0.05)
    gpio.set(RST, 1)                       # hardware reset on cold boot
    time.sleep(0.12)
    panel.init()
    panel.blit(0, 0, W - 1, H - 1, asset("base.raw"))

    bx0, by0, bx1, by1 = meta["bar"]
    mx0, my0, mx1, my1 = meta["msg"]
    width = bx1 - bx0 + 1
    rotated = meta["rotate"]
    strips = {k: asset(v) for k, v in meta["messages"].items()}

    stages = [("system", 0.12), ("containers", 0.22),
              ("supervisor", 0.30), ("services", 0.38)]
    stage, shown, drawn, progress = None, None, 0, 0.03
    supervisor_since = None
    started = time.monotonic()
    gpio.set(BL, 1)

    try:
        while time.monotonic() - started < TIMEOUT and not os.path.exists(takeover):
            # Work out the current stage
            if supervisor_since is None and os.path.exists("/run/docker.sock") \
                    and supervisor_running():
                supervisor_since = time.monotonic()
            if supervisor_since is not None:
                stage = 3 if time.monotonic() - supervisor_since > 8 else 2
            elif os.path.exists("/run/docker.sock"):
                stage = 1
            else:
                stage = 0
            key, cap = stages[stage]

            if key != shown:
                panel.blit(mx0, my0, mx1, my1, strips[key])
                shown = key

            # Ease towards the stage cap so the bar always creeps forward
            progress += max(0.0005, (cap - progress) * 0.03)
            progress = min(progress, cap)
            n = int(width * progress)
            if n > drawn:
                if rotated:
                    panel.fill(bx1 - n + 1, by0, bx1 - drawn, by1, meta["fill"])
                else:
                    panel.fill(bx0 + drawn, by0, bx0 + n - 1, by1, meta["fill"])
                drawn = n
                with open(os.path.join(BOOT_DIR, "progress"), "w") as f:
                    f.write(f"{progress:.3f}")
            time.sleep(0.1)
    finally:
        panel.close()
        gpio.close()                       # lines keep their values; the app takes over


def stop():
    jobs = subprocess.run(["systemctl", "list-jobs", "--no-legend"],
                          capture_output=True, text=True).stdout
    if "reboot.target" in jobs or "kexec.target" in jobs:
        frame = "final_reboot.raw"
    elif "poweroff.target" in jobs or "halt.target" in jobs:
        frame = "final_poweroff.raw"
    else:
        frame = "final_shutdown.raw"
    log(f"showing {frame}")

    gpio = Gpio({DC: 0, RST: 1, BL: 1})    # no reset: panel keeps its contents
    panel = Panel(gpio)
    try:
        panel.init()
        panel.blit(0, 0, W - 1, H - 1, asset(frame))
    finally:
        panel.close()
        gpio.close()


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "boot"
    try:
        if not BOOT_DIR:
            log("no boot assets yet (start the app once)")
        elif mode == "stop":
            stop()
        else:
            boot()
    except OSError as e:
        log(f"{mode}: {e}")                # e.g. EBUSY when the app owns the GPIO lines
    # Always succeed so the unit stays active and ExecStop runs at shutdown
    sys.exit(0)


if __name__ == "__main__":
    main()
