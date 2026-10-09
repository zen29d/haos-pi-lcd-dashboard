#!/usr/bin/with-contenv python3
"""Home Assistant status dashboard for a Waveshare 1.47" ST7789V3 LCD (320x172)."""

import os
import re
import sys
import json
import time
import fcntl
import signal
import struct
import socket
import urllib.error
import urllib.request
from datetime import datetime

from PIL import Image, ImageChops, ImageDraw, ImageFont

# Display
W, H = 320, 172
X_OFFSET, Y_OFFSET = 0, 34
SPI_SPEED = 10_000_000

# Boot screen hand-off with the optional host script (host: .../apps/data/<slug>/boot)
BOOT_DIR = "/data/boot"

# User options (Settings -> Apps -> HAOS Pi LCD Dashboard -> Configuration)
OPTIONS_FILE = "/data/options.json"
OPT = {
    "spi_device": "/dev/spidev0.0",
    "gpio_chip": "/dev/gpiochip0",
    "dc_pin": 25,
    "rst_pin": 27,
    "bl_pin": 18,
    "refresh_interval": 5,
    "rotate_180": False,
    "temp_warning": 70,
    "temp_critical": 80,
    "night_mode": True,
    "night_start": "23:00",
    "night_end": "07:00",
    "system_seconds": 20,
    "devices_seconds": 10,
    "device_groups": ["lights", "power", "climate", "air", "servers", "motion"],
    "theme": "advanced",
}
try:
    with open(OPTIONS_FILE) as f:
        OPT.update(json.load(f))
except (OSError, ValueError):
    pass

SPI_DEVICE, CHIP = OPT["spi_device"], OPT["gpio_chip"]
DC, RST, BL = OPT["dc_pin"], OPT["rst_pin"], OPT["bl_pin"]

# Home Assistant integration (via Supervisor proxy, no long-lived token needed)
HA_API = "http://supervisor/core/api"
HA_WS = "ws://supervisor/core/websocket"
TOKEN = os.environ.get("SUPERVISOR_TOKEN")
DISPLAY_ENTITY = "input_boolean.lcd_display"
PAGE_ENTITY = "input_select.lcd_page"
PAGE_OPTIONS = ["Auto", "System", "Devices"]
STATUS_ENTITY = "sensor.lcd_display_status"

MACHINES = {
    "raspberrypi5-64": "Raspberry Pi 5", "raspberrypi4-64": "Raspberry Pi 4",
    "raspberrypi4": "Raspberry Pi 4", "raspberrypi3-64": "Raspberry Pi 3",
    "yellow": "Home Assistant Yellow", "green": "Home Assistant Green",
    "odroid-n2": "ODROID-N2", "generic-aarch64": "ARM64 board",
}


def board_name():
    """Board name, e.g. 'Raspberry Pi 5': device tree first, then the Supervisor's machine type."""
    for path in ("/proc/device-tree/model", "/sys/firmware/devicetree/base/model"):
        try:
            with open(path) as f:
                model = f.read().strip("\x00\n ")
            return re.sub(r"\s+Model.*$|\s+Rev.*$", "", model)
        except OSError:
            pass
    try:
        req = urllib.request.Request("http://supervisor/info",
                                     headers={"Authorization": f"Bearer {TOKEN}"})
        with urllib.request.urlopen(req, timeout=3) as r:
            machine = json.load(r)["data"]["machine"]
        return MACHINES.get(machine, machine)
    except (OSError, ValueError, KeyError):
        return "Home Assistant OS"


BOARD = BOARD_SHORT = "Home Assistant OS"          # resolved in main() / preview


def resolve_board():
    global BOARD, BOARD_SHORT
    BOARD = board_name()
    BOARD_SHORT = BOARD.replace("Raspberry ", "")

# UniFi-inspired palette
BG      = (10, 13, 18)
PANEL   = (20, 26, 35)
TRACK   = (36, 45, 58)
WHITE   = (238, 243, 248)
MUTED   = (132, 145, 163)
DIM     = (88, 101, 119)
HA_BLUE = (65, 189, 245)
CYAN    = (40, 190, 255)
TEAL    = (30, 215, 160)
ORANGE  = (255, 168, 64)
RED     = (255, 84, 104)
YELLOW  = (255, 214, 90)


def tint(color, amount=0.18):
    """Blend an accent color into the background for subtle fills."""
    return tuple(int(b + (c - b) * amount) for c, b in zip(color, BG))


# Fonts: Inter (font-inter) with DejaVu (font-dejavu) as fallback
INTER_TTC = "/usr/share/fonts/inter/Inter.ttc"
DEJAVU = "/usr/share/fonts/dejavu/DejaVuSans.ttf"
DEJAVU_BOLD = "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf"


def inter_faces():
    faces = {}
    if not os.path.exists(INTER_TTC):
        return faces
    for index in range(64):
        try:
            family, style = ImageFont.truetype(INTER_TTC, 10, index=index).getname()
        except OSError:
            break
        if family == "Inter":
            faces.setdefault(style, index)
    return faces


FACES = inter_faces()


def font(style, size):
    if style in FACES:
        return ImageFont.truetype(INTER_TTC, size, index=FACES[style])
    path = DEJAVU if style in ("Regular", "Medium") else DEJAVU_BOLD
    try:
        return ImageFont.truetype(path, size)
    except OSError:
        return ImageFont.load_default(size)


F_TITLE  = font("Semi Bold", 14)
F_SUB    = font("Regular", 10)
F_PILL   = font("Semi Bold", 10)
F_LABEL  = font("Semi Bold", 10)
F_VALUE  = font("Bold", 28)
F_UNIT   = font("Medium", 13)
F_ROW    = font("Semi Bold", 12)
F_ROWSUB = font("Medium", 10)
F_FOOT   = font("Regular", 10)
F_FOOTV  = font("Semi Bold", 10)
F_BOOT_T = font("Semi Bold", 15)
F_BOOT_M = font("Medium", 11)
F_BOOT_F = font("Regular", 9)
F_FINAL  = font("Semi Bold", 13)
F_COUNT  = font("Bold", 22)
F_S_TITLE  = font("Semi Bold", 13)
F_S_STATUS = font("Semi Bold", 11)
F_S_VALUE  = font("Bold", 40)
F_S_UNIT   = font("Medium", 18)
F_S_LABEL  = font("Semi Bold", 10)
F_S_LINE   = font("Medium", 11)
F_S_COUNT  = font("Bold", 30)

# Hardware (initialised in main() so render() can be previewed without it)
spi = None
gpio = None


def init_hardware():
    global spi, gpio
    import gpiod
    from gpiod.line import Direction, Value

    spi = open(SPI_DEVICE, "wb", buffering=0)
    spi_fd = spi.fileno()
    fcntl.ioctl(spi_fd, 0x40016b01, struct.pack("B", 0))
    fcntl.ioctl(spi_fd, 0x40016b03, struct.pack("B", 8))
    fcntl.ioctl(spi_fd, 0x40046b04, struct.pack("I", SPI_SPEED))

    # Ask the host boot script to release the lines, then claim them. RST and BL
    # start high so whatever is on screen stays there (no reset flash).
    os.makedirs(BOOT_DIR, exist_ok=True)
    open(os.path.join(BOOT_DIR, "takeover"), "w").close()

    def out(value):
        return gpiod.LineSettings(direction=Direction.OUTPUT, output_value=value)

    config = {DC: out(Value.INACTIVE), RST: out(Value.ACTIVE), BL: out(Value.ACTIVE)}
    for attempt in range(50):
        try:
            gpio = gpiod.request_lines(CHIP, consumer="ha-lcd-dashboard", config=config)
            break
        except OSError:
            if attempt == 49:
                raise
            time.sleep(0.2)
    gpio.ACTIVE, gpio.INACTIVE = Value.ACTIVE, Value.INACTIVE


def pin(n, value):
    gpio.set_value(n, gpio.ACTIVE if value else gpio.INACTIVE)


def command(cmd, data=None):
    pin(DC, False)
    spi.write(bytes([cmd]))
    if data:
        pin(DC, True)
        spi.write(bytes(data))


def set_window(x0, y0, x1, y1):
    x0 += X_OFFSET
    x1 += X_OFFSET
    y0 += Y_OFFSET
    y1 += Y_OFFSET
    command(0x2A, [x0 >> 8, x0 & 255, x1 >> 8, x1 & 255])
    command(0x2B, [y0 >> 8, y0 & 255, y1 >> 8, y1 & 255])
    command(0x2C)


def init_display():
    # No hardware reset: the panel may already show the host's boot screen
    command(0x11)                  # Sleep out
    time.sleep(0.12)
    command(0x3A, [0x55])          # RGB565
    command(0x36, [0x70])          # Landscape orientation
    command(0x21)                  # Inversion on
    command(0x13)                  # Normal display mode
    command(0x29)                  # Display on
    time.sleep(0.05)
    pin(BL, True)


def display_power(on):
    if on:
        command(0x11)              # Sleep out
        time.sleep(0.12)
        command(0x29)              # Display on
        pin(BL, True)
    else:
        pin(BL, False)
        command(0x28)              # Display off
        command(0x10)              # Sleep in
        time.sleep(0.005)


# RGB888 -> RGB565 (big-endian) lookup tables
LUT_R_HI = [v & 0xF8 for v in range(256)]
LUT_G_HI = [v >> 5 for v in range(256)]
LUT_G_LO = [(v & 0x1C) << 3 for v in range(256)]
LUT_B_LO = [v >> 3 for v in range(256)]


def to_rgb565(img):
    r, g, b = img.convert("RGB").split()
    hi = ImageChops.add(r.point(LUT_R_HI), g.point(LUT_G_HI))
    lo = ImageChops.add(g.point(LUT_G_LO), b.point(LUT_B_LO))
    return Image.merge("LA", (hi, lo)).tobytes()


def screen_box(box):
    """Map a (x0, y0, x1, y1) exclusive box to panel coordinates (rotation aware)."""
    x0, y0, x1, y1 = box
    if OPT["rotate_180"]:
        return W - x1, H - y1, W - x0, H - y0
    return box


def show_image(img, box=(0, 0, W, H)):
    if OPT["rotate_180"]:
        img = img.rotate(180)
    box = screen_box(box)
    pixels = to_rgb565(img.crop(box))
    set_window(box[0], box[1], box[2] - 1, box[3] - 1)
    pin(DC, True)
    for start in range(0, len(pixels), 4096):
        spi.write(pixels[start:start + 4096])


# Metrics
last_cpu = None


def cpu_usage():
    global last_cpu
    try:
        with open("/proc/stat") as f:
            values = list(map(int, f.readline().split()[1:]))
        idle = values[3] + (values[4] if len(values) > 4 else 0)
        total = sum(values)

        result = 0
        if last_cpu:
            dt = total - last_cpu[0]
            di = idle - last_cpu[1]
            if dt > 0:
                result = max(0, min(100, 100 * (dt - di) / dt))

        last_cpu = (total, idle)
        return result
    except Exception:
        return 0


def memory():
    """Return (percent used, used GB, total GB)."""
    try:
        values = {}
        with open("/proc/meminfo") as f:
            for line in f:
                key, val = line.split(":", 1)
                values[key] = int(val.strip().split()[0])

        total = values["MemTotal"]
        available = values.get("MemAvailable", values.get("MemFree", total))
        used = total - available
        gb = 1024 * 1024
        return (100 * used / total if total else 0), used / gb, total / gb
    except Exception:
        return 0, 0, 0


def temperature():
    try:
        for zone in os.listdir("/sys/class/thermal"):
            base = f"/sys/class/thermal/{zone}"
            if not zone.startswith("thermal_zone"):
                continue
            try:
                with open(base + "/type") as f:
                    kind = f.read().strip()
                if "cpu-thermal" in kind.lower():
                    with open(base + "/temp") as f:
                        return int(f.read().strip()) / 1000
            except (OSError, ValueError):
                pass
    except OSError:
        pass
    return 0


def uptime():
    try:
        with open("/proc/uptime") as f:
            seconds = int(float(f.read().split()[0]))
        hours, rem = divmod(seconds, 3600)
        days, hours = divmod(hours, 24)
        minutes = rem // 60
        if days:
            return f"{days}d {hours}h"
        return f"{hours}h {minutes}m"
    except Exception:
        return "--"


def load_average():
    try:
        with open("/proc/loadavg") as f:
            return float(f.read().split()[0])
    except Exception:
        return 0.0


def network():
    """Return (has default route, interface, link speed in Mb/s or None, IP)."""
    iface = None
    try:
        with open("/proc/net/route") as f:
            for line in f.readlines()[1:]:
                fields = line.split()
                if len(fields) > 2 and fields[1] == "00000000":
                    iface = fields[0]
                    break
    except OSError:
        pass

    speed = None
    if iface:
        try:
            with open(f"/sys/class/net/{iface}/speed") as f:
                speed = int(f.read().strip())
            if speed <= 0:
                speed = None
        except (OSError, ValueError):
            pass

    ip = "--"
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("1.1.1.1", 9))      # no packet is sent for UDP connect
            ip = s.getsockname()[0]
    except OSError:
        pass

    return iface is not None, iface, speed, ip


# Drawing helpers
def draw_logo(img, x_out, y_out, size=24):
    # Home Assistant-style mark, drawn at 4x and downsampled for smooth edges
    ss = 4
    tile = Image.new("RGBA", (size * ss, size * ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(tile)
    x = y = 0
    size *= ss
    k = size / 24
    d.rounded_rectangle((x, y, x + size - 1, y + size - 1), radius=round(6 * k), fill=HA_BLUE)
    cx = x + size / 2
    d.polygon(
        [(cx, y + 5 * k), (x + size - 5 * k, y + 12 * k), (x + size - 5 * k, y + size - 5 * k),
         (x + 5 * k, y + size - 5 * k), (x + 5 * k, y + 12 * k)],
        fill=WHITE,
    )
    d.ellipse((cx - 2 * k, y + 12 * k, cx + 2 * k, y + 16 * k), fill=HA_BLUE)
    d.line((cx, y + 16 * k, cx, y + size - 5 * k), fill=HA_BLUE, width=max(2, round(2 * k)))
    tile = tile.resize((size // ss, size // ss), Image.LANCZOS)
    img.paste(tile, (x_out, y_out), tile)


def pill(d, right, cy, text, color):
    tw = d.textlength(text, font=F_PILL)
    w = int(tw) + 24
    x0 = right - w
    d.rounded_rectangle((x0, cy - 9, right, cy + 9), radius=9, fill=tint(color, 0.2))
    d.ellipse((x0 + 8, cy - 3, x0 + 14, cy + 3), fill=color)
    d.text((x0 + 18, cy), text, font=F_PILL, fill=color, anchor="lm")
    return x0


def update_badge(d, right, cy, n):
    """Compact cyan badge: up arrow + number of pending updates."""
    text = str(n)
    w = int(d.textlength(text, font=F_PILL)) + 26
    x0 = right - w
    d.rounded_rectangle((x0, cy - 9, right, cy + 9), radius=9, fill=tint(CYAN, 0.2))
    ax = x0 + 11
    d.line([(ax, cy - 4), (ax, cy + 4)], fill=CYAN, width=2)
    d.line([(ax - 3.5, cy - 0.5), (ax, cy - 4), (ax + 3.5, cy - 0.5)], fill=CYAN, width=2, joint="curve")
    d.text((x0 + 18, cy), text, font=F_PILL, fill=CYAN, anchor="lm")
    return x0


def metric_tile(d, x0, x1, y0, y1, label, value, unit, color, ratio):
    d.rounded_rectangle((x0, y0, x1, y1), radius=8, fill=PANEL)
    px = x0 + 10

    d.text((px, y0 + 9), label, font=F_LABEL, fill=MUTED)

    baseline = y0 + 44
    d.text((px, baseline), value, font=F_VALUE, fill=WHITE, anchor="ls")
    vx = px + d.textlength(value, font=F_VALUE) + 2
    d.text((vx, baseline), unit, font=F_UNIT, fill=MUTED, anchor="ls")

    by = y1 - 11
    bx1 = x1 - 10
    d.rounded_rectangle((px, by, bx1, by + 4), radius=2, fill=TRACK)
    fill_w = int((bx1 - px) * max(0.0, min(1.0, ratio)))
    if fill_w >= 4:
        d.rounded_rectangle((px, by, px + fill_w, by + 4), radius=2, fill=color)


def status_tile(d, x0, x1, y0, y1, icon, title, status, color):
    d.rounded_rectangle((x0, y0, x1, y1), radius=8, fill=PANEL)
    cy = (y0 + y1) // 2
    ix = x0 + 9
    d.rounded_rectangle((ix, cy - 12, ix + 23, cy + 11), radius=6, fill=tint(color, 0.22))
    icon(d, ix + 12, cy, color)

    tx = ix + 32
    d.text((tx, cy - 2), title, font=F_ROW, fill=WHITE, anchor="ls")
    d.text((tx, cy + 12), status, font=F_ROWSUB, fill=color, anchor="ls")


def icon_health(d, cx, cy, color, ok=True):
    if ok:                                                   # check mark
        d.line([(cx - 5, cy), (cx - 1.5, cy + 4), (cx + 5, cy - 4)], fill=color, width=2, joint="curve")
    else:                                                    # exclamation mark
        d.line([(cx, cy - 6), (cx, cy + 1)], fill=color, width=2)
        d.ellipse((cx - 1.5, cy + 3.5, cx + 1.5, cy + 6.5), fill=color)


def icon_network(d, cx, cy, color):
    # Three connected nodes
    top, left, right = (cx, cy - 5), (cx - 5, cy + 5), (cx + 5, cy + 5)
    d.line((top, left), fill=color, width=1)
    d.line((top, right), fill=color, width=1)
    for px, py in (top, left, right):
        d.ellipse((px - 2, py - 2, px + 2, py + 2), fill=color)


def foot_item(d, x, y, label, value, anchor="l"):
    lw = d.textlength(label + " ", font=F_FOOT)
    vw = d.textlength(value, font=F_FOOTV)
    if anchor == "r":
        x -= lw + vw
    elif anchor == "m":
        x -= (lw + vw) / 2
    d.text((x, y), label, font=F_FOOT, fill=DIM, anchor="ls")
    d.text((x + lw, y), value, font=F_FOOTV, fill=MUTED, anchor="ls")


def overall_status(s):
    """Header badge: network first, then global HA health, then temperature."""
    level = health()[0]
    if not s["route"]:
        return "Offline", RED
    if level == "error":
        return "Error", RED
    if level == "warning" or s["temp"] >= OPT["temp_critical"]:
        return "Warning", ORANGE
    return "Online", TEAL


def render(s):
    if OPT["theme"] == "simple":
        return render_simple(s)
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    M, GAP = 8, 6

    # Header
    draw_logo(img, M, 6)
    d.text((M + 32, 18), "Home Assistant", font=F_TITLE, fill=WHITE, anchor="ls")
    sub = f"{BOARD_SHORT} · {HA['version']}" if HA["version"] else BOARD
    d.text((M + 32, 30), sub, font=F_SUB, fill=MUTED, anchor="ls")

    label, color = overall_status(s)
    x = pill(d, W - M, 18, label, color)
    if HA["updates"]:
        update_badge(d, x - 5, 18, HA["updates"])

    # Metric tiles
    y0, y1 = 38, 98
    tw = (W - 2 * M - 2 * GAP) // 3
    xs = [M + i * (tw + GAP) for i in range(3)]
    hot = lambda v, c: RED if v >= 90 else c

    metric_tile(d, xs[0], xs[0] + tw, y0, y1, "CPU",
                f"{s['cpu']:.0f}", "%", hot(s["cpu"], CYAN), s["cpu"] / 100)
    metric_tile(d, xs[1], xs[1] + tw, y0, y1, "MEMORY",
                f"{s['ram']:.0f}", "%", hot(s["ram"], TEAL), s["ram"] / 100)
    metric_tile(d, xs[2], W - M - 1, y0, y1, "TEMP",
                f"{s['temp']:.0f}", "°C",
                RED if s["temp"] >= OPT["temp_warning"] else ORANGE,
                s["temp"] / 85)

    # Status tiles
    y0, y1 = 104, 142
    half = (W - 2 * M - GAP) // 2
    level, title, detail = health()
    h_color = {"ok": TEAL, "warning": ORANGE, "error": RED, "unknown": MUTED}[level]
    icon = lambda d, cx, cy, c: icon_health(d, cx, cy, c, ok=level == "ok")
    status_tile(d, M, M + half, y0, y1, icon, title, detail, h_color)
    if s["route"]:
        link = f"{s['iface']} · {s['speed'] // 1000}G" if s["speed"] and s["speed"] >= 1000 \
            else f"{s['iface']} · {s['speed']}M" if s["speed"] else s["iface"]
        net_status, net_color = f"Online · {link}", TEAL
    else:
        net_status, net_color = "No route", RED
    status_tile(d, M + half + GAP, W - M - 1, y0, y1, icon_network,
                s["ip"], net_status, net_color)

    # Footer
    fy = 162
    foot_item(d, M + 2, fy, "Uptime", s["uptime"])
    foot_item(d, W // 2, fy, "Load", f"{s['load']:.2f}", anchor="m")
    foot_item(d, W - M - 2, fy, "RAM", f"{s['mem_used']:.1f}/{s['mem_total']:.0f} GB", anchor="r")

    return img


# Simple theme: no cards, big numbers, detail only when something needs attention
def simple_header(d, title, status, color):
    d.ellipse((10, 10, 17, 17), fill=color)
    d.text((24, 18), title, font=F_S_TITLE, fill=WHITE, anchor="ls")
    d.text((W - 12, 18), status, font=F_S_STATUS, fill=color, anchor="rs")


def render_simple(s):
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    label, color = overall_status(s)
    if HA["updates"] and color == TEAL:
        label = f"{HA['updates']} update{'s' if HA['updates'] > 1 else ''}"
        color = CYAN
    simple_header(d, "Home Assistant", label, color)

    temp_color = RED if s["temp"] >= OPT["temp_warning"] else ORANGE
    cols = [(53, f"{s['cpu']:.0f}", "%", "CPU", CYAN, s["cpu"] / 100),
            (160, f"{s['ram']:.0f}", "%", "MEMORY", TEAL, s["ram"] / 100),
            (267, f"{s['temp']:.0f}", "°", "TEMP", temp_color, s["temp"] / 85)]
    for cx, value, unit, name, c, ratio in cols:
        vw = d.textlength(value, font=F_S_VALUE)
        uw = d.textlength(unit, font=F_S_UNIT)
        x = cx - (vw + uw + 2) / 2
        d.text((x, 84), value, font=F_S_VALUE, fill=WHITE, anchor="ls")
        d.text((x + vw + 2, 84), unit, font=F_S_UNIT, fill=MUTED, anchor="ls")
        d.text((cx, 102), name, font=F_S_LABEL, fill=MUTED, anchor="ms")
        d.rounded_rectangle((cx - 20, 110, cx + 19, 112), radius=1, fill=TRACK)
        n = max(3, round(39 * max(0.0, min(1.0, ratio))))
        d.rounded_rectangle((cx - 20, 110, cx - 20 + n, 112), radius=1, fill=c)

    level, title, detail = health()
    h_color = {"ok": TEAL, "warning": ORANGE, "error": RED, "unknown": MUTED}[level]
    line = title if level == "ok" else f"{title} · {detail}"
    if HA["updates"] and color != CYAN:                      # header is busy with a warning
        line += f" · ↑{HA['updates']}"
    d.ellipse((13, 138, 19, 144), fill=h_color)
    d.text((25, 145), line, font=F_S_LINE, fill=WHITE, anchor="ls")
    ip_w = d.textlength(s["ip"], font=F_S_LINE)
    n_color = TEAL if s["route"] else RED
    d.ellipse((W - 12 - ip_w - 12, 138, W - 12 - ip_w - 6, 144), fill=n_color)
    d.text((W - 12, 145), s["ip"], font=F_S_LINE, fill=WHITE, anchor="rs")
    d.text((W // 2, 162), f"Up {s['uptime']}  ·  Load {s['load']:.2f}", font=F_FOOT, fill=DIM, anchor="ms")
    return img


def render_devices_simple():
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    groups = HA["groups"]
    total = sum(g["n"] for g in groups)
    offline = sum(g["offline"] for g in groups)
    if offline:
        simple_header(d, "Devices", f"{total - offline} of {total} online", ORANGE)
    else:
        simple_header(d, "Devices", f"{total} online", TEAL)

    for i, g in enumerate(groups[:6]):
        cx = (53, 160, 267)[i % 3]
        y = 70 if i < 3 else 128
        label, kind, color = GROUPS[g["key"]]
        attention = ORANGE if g["offline"] else (CYAN if g["tone"] == "alert" else None)
        n = str(g["n"])
        nw = d.textlength(n, font=F_S_COUNT)
        x = cx - (nw + 22) / 2
        device_icon(img, kind, x + 7, y - 10, attention or color)
        d.text((x + 22, y), n, font=F_S_COUNT, fill=attention or WHITE, anchor="ls")
        d.text((cx, y + 17), label.upper(), font=F_S_LABEL, fill=attention or MUTED, anchor="ms")
    return img


# Devices page: every physical device in HA, grouped by type
GROUPS = {
    # key: (label, icon, color)
    "lights":  ("Lights",  "light",   YELLOW),
    "power":   ("Power",   "power",   ORANGE),
    "climate": ("Climate", "climate", CYAN),
    "air":     ("Air",     "air",     TEAL),
    "servers": ("Servers", "server",  HA_BLUE),
    "motion":  ("Motion",  "motion",  CYAN),
    "phones":  ("Phones",  "phone",   HA_BLUE),
}
TONES = {"on": TEAL, "value": WHITE, "warn": ORANGE, "alert": CYAN, "dim": DIM}


def device_icon(img, kind, cx, cy, color):
    """Small line icon (about 12 px), drawn at 4x and downsampled."""
    s = 4
    tile = Image.new("RGBA", (16 * s, 16 * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(tile)
    c = 8 * s
    P = lambda x, y: (c + x * s, c + y * s)                  # icon units -> pixels
    w = round(1.6 * s)

    def dot(x, y, r):
        (px, py) = P(x, y)
        d.ellipse((px - r * s, py - r * s, px + r * s, py + r * s), fill=color)

    def box(x0, y0, x1, y1, r):
        d.rounded_rectangle((*P(x0, y0), *P(x1, y1)), radius=r * s, outline=color, width=w)

    def arc(x, y, r, a0, a1):
        (px, py) = P(x, y)
        d.arc((px - r * s, py - r * s, px + r * s, py + r * s), a0, a1, fill=color, width=w)

    if kind == "light":
        arc(0, -1.5, 3.6, 144, 396)
        d.line([P(-2.9, 0.6), P(-1.6, 3), P(1.6, 3), P(2.9, 0.6)], fill=color, width=w, joint="curve")
        d.line([P(-1.5, 5), P(1.5, 5)], fill=color, width=w)
    elif kind == "power":
        d.polygon([P(1, -6), P(-3.5, 0.5), P(0, 0.5), P(-1, 6), P(3.5, -0.5), P(0, -0.5)], fill=color)
    elif kind == "climate":
        box(-1.8, -6, 1.8, 2, 1.8)
        dot(0, 3.5, 2.8)
    elif kind == "air":
        d.line([P(-5, -2.5), P(2, -2.5)], fill=color, width=w)
        arc(2, -4.2, 1.7, -108, 90)
        d.line([P(-5, 1), P(4, 1)], fill=color, width=w)
        d.line([P(-3, 4), P(1, 4)], fill=color, width=w)
    elif kind == "server":
        box(-5.5, -4, 5.5, -0.4, 1)
        box(-5.5, 0.5, 5.5, 4.1, 1)
        dot(3, -2.2, 0.9)
        dot(3, 2.3, 0.9)
    elif kind == "motion":
        dot(-3, 3, 1.6)
        arc(-3, 3, 5, -90, 0)
        arc(-3, 3, 8, -90, 0)
    elif kind == "phone":
        box(-3.5, -6, 3.5, 6, 1.5)
        dot(0, 3.8, 0.9)

    tile = tile.resize((16, 16), Image.LANCZOS)
    img.paste(tile, (round(cx - 8), round(cy - 8)), tile)


def page_indicator(d, page, frac):
    """Two short bars under the footer; the active one fills as its time runs out."""
    w, gap, y = 14, 4, 168
    x0 = W // 2 - w - gap // 2
    for i in range(2):
        x = x0 + i * (w + gap)
        d.rounded_rectangle((x, y, x + w - 1, y + 1), radius=1, fill=TRACK)
        if i == page:
            n = max(2, round(w * max(0.0, min(1.0, frac))))
            d.rounded_rectangle((x, y, x + n - 1, y + 1), radius=1, fill=MUTED)


INDICATOR_BOX = (W // 2 - 20, 166, W // 2 + 20, 171)


def render_devices():
    if OPT["theme"] == "simple":
        return render_devices_simple()
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    M = 8
    groups = HA["groups"]
    total = sum(g["n"] for g in groups)
    offline = sum(g["offline"] for g in groups)

    draw_logo(img, M, 6)
    d.text((M + 32, 18), "Devices", font=F_TITLE, fill=WHITE, anchor="ls")
    d.text((M + 32, 30), " · ".join(HA["protocols"][:4]) or "Home Assistant",
           font=F_SUB, fill=MUTED, anchor="ls")
    if offline:
        pill(d, W - M, 18, f"{total - offline} of {total} online", ORANGE)
    else:
        pill(d, W - M, 18, f"{total} online", TEAL)

    xs = [8, 111, 214]
    for i, g in enumerate(groups[:6]):
        x0 = xs[i % 3]
        x1 = 311 if i % 3 == 2 else x0 + 97
        y0 = 38 if i < 3 else 101
        y1 = y0 + 58
        label, kind, color = GROUPS[g["key"]]
        if g["offline"]:
            color = ORANGE
        d.rounded_rectangle((x0, y0, x1, y1), radius=8, fill=PANEL)
        d.rounded_rectangle((x0 + 9, y0 + 9, x0 + 26, y0 + 26), radius=5, fill=tint(color, 0.22))
        device_icon(img, kind, x0 + 17.5, y0 + 17.5, color)
        d.text((x1 - 10, y0 + 27), str(g["n"]), font=F_COUNT, fill=WHITE, anchor="rs")
        d.text((x0 + 10, y0 + 43), label.upper(), font=F_LABEL, fill=MUTED, anchor="ls")
        d.text((x0 + 10, y0 + 54), g["status"], font=F_ROWSUB, fill=TONES[g["tone"]], anchor="ls")
    return img


# Boot screen (UniFi style: logo, thin progress bar, status line)
BOOT_BAR = (70, 104, 250, 108)          # exclusive box
BOOT_MSG = (0, 116, W, 136)
BOOT_MESSAGES = {
    "system": "Starting system",
    "containers": "Starting containers",
    "supervisor": "Starting Supervisor",
    "services": "Starting services",
}


def boot_frame(img, d, title="Home Assistant"):
    draw_logo(img, (W - 40) // 2, 18, 40)
    d.text((W // 2, 84), title, font=F_BOOT_T, fill=WHITE, anchor="ms")
    d.text((W // 2, 162), f"{BOARD} · HAOS", font=F_BOOT_F, fill=DIM, anchor="ms")


def render_boot(progress, message):
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    boot_frame(img, d)
    x0, y0, x1, y1 = BOOT_BAR
    d.rounded_rectangle((x0, y0, x1 - 1, y1 - 1), radius=2, fill=TRACK)
    if progress:
        n = int((x1 - x0) * min(1.0, progress))
        if n >= 4:
            d.rounded_rectangle((x0, y0, x0 + n - 1, y1 - 1), radius=2, fill=HA_BLUE)
    if message:
        d.text((W // 2, 130), message, font=F_BOOT_M, fill=MUTED, anchor="ms")
    return img


def render_final(message, detail=None, color=MUTED):
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    boot_frame(img, d)
    d.text((W // 2, 116), message, font=F_FINAL, fill=WHITE, anchor="ms")
    if detail:
        d.text((W // 2, 134), detail, font=F_BOOT_M, fill=color, anchor="ms")
    return img


def write_boot_assets():
    """Pre-render the host boot script's artwork as raw RGB565 (rotation applied)."""
    def raw(img, box=(0, 0, W, H)):
        if OPT["rotate_180"]:
            img = img.rotate(180)
        return to_rgb565(img.crop(screen_box(box)))

    def rgb565(c):
        return ((c[0] & 0xF8) << 8) | ((c[1] & 0xFC) << 3) | (c[2] >> 3)

    def inclusive(box):
        x0, y0, x1, y1 = screen_box(box)
        return [x0, y0, x1 - 1, y1 - 1]

    files = {
        "base.raw": raw(render_boot(0, None)),
        "final_reboot.raw": raw(render_final("Restarting…", "Back in about a minute")),
        "final_poweroff.raw": raw(render_final("Powered off", "Safe to unplug", TEAL)),
        "final_shutdown.raw": raw(render_final("Shutting down…")),
    }
    for key, text in BOOT_MESSAGES.items():
        files[f"msg_{key}.raw"] = raw(render_boot(0, text), BOOT_MSG)
    files["meta.json"] = json.dumps({
        "bar": inclusive(BOOT_BAR),
        "msg": inclusive(BOOT_MSG),
        "rotate": OPT["rotate_180"],
        "fill": rgb565(HA_BLUE),
        "pins": {"dc": DC, "rst": RST, "bl": BL},
        "spi": SPI_DEVICE,
        "chip": CHIP,
        "messages": {k: f"msg_{k}.raw" for k in BOOT_MESSAGES},
    }).encode()

    os.makedirs(BOOT_DIR, exist_ok=True)
    for name, data in files.items():
        tmp = os.path.join(BOOT_DIR, name + ".tmp")
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, os.path.join(BOOT_DIR, name))


def collect():
    ram, mem_used, mem_total = memory()
    route, iface, speed, ip = network()
    return {
        "cpu": cpu_usage(),
        "ram": ram,
        "mem_used": mem_used,
        "mem_total": mem_total,
        "temp": temperature(),
        "load": load_average(),
        "uptime": uptime(),
        "route": route,
        "iface": iface,
        "speed": speed,
        "ip": ip,
    }


def ha_request(method, path, body=None):
    req = urllib.request.Request(
        HA_API + path,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": f"Bearer {TOKEN}",
                 "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=3) as r:
        return json.load(r)


def helper_state(entity_id):
    """State of a helper entity, 'missing', or None if HA is unreachable."""
    if not TOKEN:
        return None
    try:
        return ha_request("GET", f"/states/{entity_id}")["state"]
    except urllib.error.HTTPError as e:
        return "missing" if e.code == 404 else None
    except (OSError, ValueError, KeyError):
        return None


def core_state():
    """Home Assistant Core state ('RUNNING', 'STARTING', ...) or None if unreachable."""
    if not TOKEN:
        return "RUNNING"                      # no API access: skip boot screens
    try:
        return ha_request("GET", "/config").get("state")
    except (OSError, ValueError):
        return None


def boot_sequence(progress, waiting_message, timeout=600):
    """Animate the boot screen until Home Assistant Core reports RUNNING."""
    msg, cap = waiting_message, 0.75
    shown_msg, shown_n = None, -1
    started = next_check = time.monotonic()
    x0, _, x1, _ = BOOT_BAR

    show_image(render_boot(progress, msg))
    while time.monotonic() - started < timeout:
        now = time.monotonic()
        if now >= next_check:
            next_check = now + 1
            state = core_state()
            if state == "RUNNING":
                break
            if state is None:
                msg, cap = waiting_message, 0.75
            else:
                msg, cap = "Loading integrations", 0.95
                progress = max(progress, 0.75)

        progress = min(cap, progress + max(0.0005, (cap - progress) * 0.02))
        n = int((x1 - x0) * progress)
        if msg != shown_msg or n != shown_n:
            img = render_boot(progress, msg)
            if msg != shown_msg:
                show_image(img, BOOT_MSG)
            show_image(img, BOOT_BAR)
            shown_msg, shown_n = msg, n
        time.sleep(0.1)

    # Finish the bar, then hand over to the dashboard
    while progress < 1.0:
        progress = min(1.0, progress + 0.04)
        show_image(render_boot(progress, "Ready"), BOOT_BAR)
        time.sleep(0.02)
    show_image(render_boot(1.0, "Ready"), BOOT_MSG)
    time.sleep(0.6)


def system_shutting_down():
    """True when the Supervisor is shutting the whole system down (or is gone)."""
    try:
        req = urllib.request.Request(
            "http://supervisor/info", headers={"Authorization": f"Bearer {TOKEN}"})
        with urllib.request.urlopen(req, timeout=2) as r:
            state = json.load(r)["data"]["state"]
        return state in ("shutdown", "stopping", "close")
    except (OSError, ValueError, KeyError):
        return True


def ws_call(*messages):
    """Run websocket commands in one connection and return their results in order."""
    import websocket

    ws = websocket.create_connection(HA_WS, timeout=10)
    try:
        ws.recv()                                            # auth_required
        ws.send(json.dumps({"type": "auth", "access_token": TOKEN}))
        if json.loads(ws.recv()).get("type") != "auth_ok":
            raise RuntimeError("websocket auth failed")
        for i, msg in enumerate(messages, 1):
            ws.send(json.dumps({"id": i, **msg}))
        results = {}
        while len(results) < len(messages):
            r = json.loads(ws.recv())
            if r.get("type") != "result":
                continue
            if not r.get("success"):
                raise RuntimeError(r.get("error"))
            results[r["id"]] = r["result"]
        return [results[i] for i in range(1, len(messages) + 1)]
    finally:
        ws.close()


# Home Assistant view; None = unknown (HA unreachable)
HA = {"version": None, "updates": 0, "groups": [], "protocols": [],
      "repair_errors": 0, "repair_warnings": 0, "failing": 0, "offline": 0, "log_errors": 0}
FAILED_STATES = {"setup_error", "setup_retry", "migration_error", "failed_unload"}


def health():
    """Global Home Assistant health: (level, title, detail). Level: ok/warning/error/unknown."""
    if HA["version"] is None:
        return "unknown", "Health", "HA unreachable"
    errors = HA["repair_errors"] + HA["failing"]
    warnings = HA["repair_warnings"] + HA["offline"]
    parts = []
    repairs = HA["repair_errors"] + HA["repair_warnings"]
    if repairs:
        parts.append(f"{repairs} repair{'s' if repairs > 1 else ''}")
    if HA["failing"]:
        parts.append(f"{HA['failing']} failing")
    if HA["offline"]:
        parts.append(f"{HA['offline']} offline")
    issues = errors + warnings
    if issues:
        title = f"{issues} issue{'s' if issues > 1 else ''}"
        return ("error" if errors else "warning"), title, " · ".join(parts)
    if HA["log_errors"]:
        n = HA["log_errors"]
        return "ok", "All good", f"{n} log error{'s' if n > 1 else ''}"
    return "ok", "All good", "Nothing to fix"


SKIP_INTEGRATIONS = {"hassio", "bluetooth", "raspberry_pi", "rpi_power", "homekit"}
PROTOCOLS = {"zha": "Zigbee", "zigbee2mqtt": "Zigbee", "matter": "Matter", "thread": "Thread",
             "mqtt": "MQTT", "esphome": "ESPHome", "zwave_js": "Z-Wave"}
AIR_CLASSES = {"pm25", "pm10", "pm1", "aqi", "carbon_dioxide", "volatile_organic_compounds",
               "volatile_organic_compounds_parts", "nitrogen_dioxide", "ozone"}
MOTION_CLASSES = {"motion", "occupancy", "presence", "door", "window", "opening", "garage_door"}


def number(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def classify(device, ents, integrations, states):
    """Pick a device group, or None for devices the LCD should not count."""
    labels = {l.replace("_", "-") for l in device.get("labels") or []}
    if "lcd-hide" in labels:
        return None
    for key in GROUPS:
        if f"lcd-{key}" in labels:
            return key
    if device.get("entry_type") == "service" or integrations & SKIP_INTEGRATIONS:
        return None
    if "mobile_app" in integrations:
        return "phones"
    if not ents:
        return None

    domains = {e["entity_id"].split(".")[0] for e in ents}
    classes = {states.get(e["entity_id"], {}).get("attributes", {}).get("device_class")
               for e in ents}
    area = (device.get("area_id") or "").lower()

    if classes & AIR_CLASSES or "fan" in domains:
        return "air"
    if "light" in domains:
        return "lights"
    if "server" in area or "rack" in area or ("mqtt" in integrations and not domains & {"switch", "light"}):
        return "servers"
    if "switch" in domains or classes & {"power", "energy", "outlet"}:
        return "power"
    if classes & MOTION_CLASSES:
        return "motion"
    if classes & {"temperature", "humidity"}:
        return "climate"
    return None


def summarize(key, members, states):
    """One short status line per group: (text, tone)."""
    def values(device_class=None, domain=None):
        out = []
        for _, ents in members:
            for e in ents:
                st = states.get(e["entity_id"])
                if not st or st["state"] in ("unavailable", "unknown"):
                    continue
                if domain and not e["entity_id"].startswith(domain + "."):
                    continue
                if device_class and st.get("attributes", {}).get("device_class") != device_class:
                    continue
                out.append(st)
        return out

    def nums(device_class):
        found = []
        for st in values(device_class):
            v = number(st["state"])
            if v is not None:
                unit = st.get("attributes", {}).get("unit_of_measurement")
                found.append(v * 1000 if unit == "kW" else v)
        return found

    if key == "lights":
        on = sum(1 for st in values(domain="light") if st["state"] == "on")
        return (f"{on} on", "on") if on else ("All off", "dim")
    if key == "power":
        watts = sum(nums("power"))
        if watts:
            return (f"{watts / 1000:.1f} kW" if watts >= 1000 else f"{watts:.0f} W"), "value"
        on = sum(1 for st in values(domain="switch") if st["state"] == "on")
        return (f"{on} on", "on") if on else ("All off", "dim")
    if key == "climate":
        t, h = nums("temperature"), nums("humidity")
        if t and h:
            return f"{sum(t) / len(t):.1f}° · {sum(h) / len(h):.0f}%", "value"
        if t:
            return f"{sum(t) / len(t):.1f}°C", "value"
        return "--", "dim"
    if key == "air":
        # Prefer indoor sensors; outdoor air is not something the house can fix
        indoor = [m for m in members if "outdoor" not in (m[0].get("area_id") or "")]
        if indoor and len(indoor) < len(members):
            return summarize(key, indoor, states)
        pm = nums("pm25")
        if pm:
            worst = max(pm)
            return f"PM2.5 {worst:.0f}", ("warn" if worst > 35 else "value")
        on = sum(1 for st in values(domain="fan") if st["state"] == "on")
        return (f"{on} on", "on") if on else ("Off", "dim")
    if key == "servers":
        t = nums("temperature")
        return (f"Max {max(t):.0f}°C", "warn" if max(t) >= 75 else "value") if t else ("Online", "on")
    if key == "motion":
        active = [st for st in values(domain="binary_sensor")
                  if st["state"] == "on"
                  and st.get("attributes", {}).get("device_class") in MOTION_CLASSES]
        if not active:
            return "Clear", "dim"
        moving = [st for st in active if st["attributes"]["device_class"] in ("motion", "occupancy", "presence")]
        return ("Motion", "alert") if moving else (f"{len(active)} open", "alert")
    if key == "phones":
        home = sum(1 for st in values(domain="device_tracker") if st["state"] == "home")
        return f"{home} home", ("on" if home else "dim")
    return "", "dim"


def group_devices(devices, entities, entries, states):
    domain_of = {e["entry_id"]: e["domain"] for e in entries}
    ents_of = {}
    for e in entities:
        if e.get("device_id") and not e.get("disabled_by") and not e.get("hidden_by"):
            ents_of.setdefault(e["device_id"], []).append(e)

    members = {key: [] for key in GROUPS}
    protocols = []
    for dev in devices:
        if dev.get("disabled_by"):
            continue
        integrations = {domain_of.get(c, "") for c in dev["config_entries"]}
        ents = ents_of.get(dev["id"], [])
        key = classify(dev, ents, integrations, states)
        if key is None:
            continue
        members[key].append((dev, ents))
        if key in OPT["device_groups"]:
            for i in sorted(integrations):
                name = PROTOCOLS.get(i, "Wi-Fi")
                if name not in protocols:
                    protocols.append(name)

    all_offline = sum(
        1 for key in members for _, ents in members[key]
        if ents and all(states.get(e["entity_id"], {}).get("state", "unavailable") == "unavailable"
                        for e in ents)
    )
    groups = []
    for key in OPT["device_groups"]:
        if key not in GROUPS or not members[key]:
            continue
        offline = sum(
            1 for _, ents in members[key]
            if ents and all(states.get(e["entity_id"], {}).get("state", "unavailable") == "unavailable"
                            for e in ents)
        )
        text, tone = summarize(key, members[key], states)
        if offline:
            text, tone = f"{offline} offline", "warn"
        groups.append({"key": key, "n": len(members[key]), "offline": offline,
                       "status": text, "tone": tone})
    order = ["Zigbee", "Matter", "Thread", "Z-Wave", "Wi-Fi", "ESPHome", "MQTT"]
    protocols.sort(key=lambda p: order.index(p) if p in order else 99)
    return groups, protocols, all_offline


def poll_ha():
    if not TOKEN:
        return
    try:
        config, entries, devices, entities, states, issues, logs = ws_call(
            {"type": "get_config"},
            {"type": "config_entries/get"},
            {"type": "config/device_registry/list"},
            {"type": "config/entity_registry/list"},
            {"type": "get_states"},
            {"type": "repairs/list_issues"},
            {"type": "system_log/list"},
        )
    except Exception as e:
        print(f"HA poll failed: {e}", flush=True)
        HA.update(version=None, updates=0, groups=[], protocols=[])
        return

    full_states = {s["entity_id"]: s for s in states}
    try:
        HA["groups"], HA["protocols"], HA["offline"] = group_devices(
            devices, entities, entries, full_states)
    except Exception as e:                                   # never break the System page
        print(f"Device grouping failed: {e}", flush=True)
        HA["groups"], HA["protocols"], HA["offline"] = [], [], 0

    HA["version"] = config.get("version")
    # Every update entity: Core, OS, Supervisor, apps, HACS, device firmware
    HA["updates"] = sum(
        1 for eid, st in full_states.items() if eid.startswith("update.") and st["state"] == "on"
    )
    # Repairs (Settings -> System -> Repairs) also carry Supervisor/OS problems
    active = [i for i in issues.get("issues", []) if not i.get("ignored")]
    HA["repair_errors"] = sum(1 for i in active if i.get("severity") in ("critical", "error"))
    HA["repair_warnings"] = sum(1 for i in active if i.get("severity") == "warning")
    HA["failing"] = sum(1 for e in entries if e.get("state") in FAILED_STATES)
    HA["log_errors"] = sum(1 for entry in logs if entry.get("level") in ("ERROR", "CRITICAL"))


def create_display_switch():
    """Create the input_boolean helper (editable in the HA UI) and turn it on."""
    ws_call({"type": "input_boolean/create",
             "name": "LCD Display", "icon": "mdi:monitor-small"})
    ha_request("POST", "/services/input_boolean/turn_on",
               {"entity_id": DISPLAY_ENTITY})


def create_page_select():
    """Create the input_select helper used to pin a page (first option = Auto)."""
    ws_call({"type": "input_select/create", "name": "LCD Page",
             "options": PAGE_OPTIONS, "icon": "mdi:monitor-dashboard"})


def publish_status(state):
    if not TOKEN:
        return
    try:
        ha_request("POST", f"/states/{STATUS_ENTITY}", {
            "state": state,
            "attributes": {
                "friendly_name": "LCD Display Status",
                "icon": "mdi:monitor" if state == "on" else "mdi:monitor-off",
                "night_mode": OPT["night_mode"],
                "night_start": OPT["night_start"],
                "night_end": OPT["night_end"],
            },
        })
    except (OSError, ValueError):
        pass


def minutes(hhmm):
    h, m = hhmm.split(":")
    return int(h) * 60 + int(m)


def is_night():
    if not OPT["night_mode"]:
        return False
    try:
        start, end = minutes(OPT["night_start"]), minutes(OPT["night_end"])
    except ValueError:
        return False
    now = datetime.now()
    m = now.hour * 60 + now.minute
    if start == end:
        return False
    if start < end:
        return start <= m < end
    return m >= start or m < end                             # spans midnight


def main():
    resolve_board()
    # Preview without hardware: run.sh preview <system|devices|boot|final> [advanced|simple] out.png
    if len(sys.argv) > 3 and sys.argv[1] == "preview":
        what, out = sys.argv[2], sys.argv[-1]
        if len(sys.argv) > 4:
            OPT["theme"] = sys.argv[3]
        if what == "boot":
            render_boot(0.42, "Starting Home Assistant").save(out)
        elif what == "final":
            render_final("Powered off", "Safe to unplug", TEAL).save(out)
        else:
            cpu_usage()
            poll_ha()
            time.sleep(0.5)
            img = render(collect()) if what == "system" else render_devices()
            page_indicator(ImageDraw.Draw(img), 0 if what == "system" else 1, 0.4)
            img.save(out)
        return

    print(f"Fonts: {'Inter' if FACES else 'DejaVu fallback'}", flush=True)
    print(f"Options: {OPT}", flush=True)
    write_boot_assets()
    init_hardware()
    init_display()

    def shutdown(*_):
        if system_shutting_down():
            # Leave the panel on; the host script shows the final screen
            print("System shutting down", flush=True)
            show_image(render_final("Shutting down…"))
        else:
            display_power(False)
            publish_status("off")
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)

    # Continue the host boot screen if Home Assistant is still starting
    if core_state() != "RUNNING":
        try:
            with open(os.path.join(BOOT_DIR, "progress")) as f:
                start = float(f.read()) if time.time() - os.path.getmtime(f.name) < 120 else 0.3
        except (OSError, ValueError):
            start = 0.3
        print("Home Assistant starting: boot screen", flush=True)
        boot_sequence(max(start, 0.3), "Starting Home Assistant")

    state = "on"
    next_render = 0
    next_publish = 0
    next_create = 0
    next_poll = 0
    unreachable = 0
    page, page_started, last_img = 0, time.monotonic(), None
    durations = (OPT["system_seconds"], OPT["devices_seconds"])

    while True:
        now = time.monotonic()
        switch = helper_state(DISPLAY_ENTITY)
        mode = helper_state(PAGE_ENTITY) if switch is not None else None

        if mode == "missing" and now >= next_create:
            try:
                create_page_select()
                print(f"Created {PAGE_ENTITY}", flush=True)
            except Exception as e:
                print(f"Could not create {PAGE_ENTITY}: {e}", flush=True)

        # Home Assistant Core went away while the screen is on -> restart screen
        unreachable = unreachable + 1 if switch is None and TOKEN else 0
        if unreachable >= 3 and state == "on":
            print("Home Assistant restarting: boot screen", flush=True)
            boot_sequence(0.3, "Home Assistant restarting")
            unreachable, next_render, next_poll = 0, 0, 0
            continue

        if switch == "missing" and now >= next_create:
            try:
                create_display_switch()
                print(f"Created {DISPLAY_ENTITY}", flush=True)
                switch = "on"
            except Exception as e:
                print(f"Could not create {DISPLAY_ENTITY}: {e}", flush=True)
        if "missing" in (switch, mode) and now >= next_create:
            next_create = now + 300

        # Helper missing or HA unreachable -> keep the screen on
        if switch == "off":
            wanted = "off"
        elif is_night():
            wanted = "night"
        else:
            wanted = "on"

        if wanted != state:
            print(f"Display: {state} -> {wanted}", flush=True)
            display_power(wanted == "on")
            state = wanted
            next_render = next_publish = next_poll = 0

        # Page selection: pinned from HA, or rotating in Auto
        auto = mode not in ("System", "Devices")
        if not HA["groups"]:
            wanted_page = 0                                  # nothing to show yet
        elif mode == "System":
            wanted_page = 0
        elif mode == "Devices":
            wanted_page = 1
        elif now - page_started >= durations[page]:
            wanted_page = 1 - page
        else:
            wanted_page = page
        if wanted_page != page:
            page, page_started, next_render = wanted_page, now, 0
            if page == 1:
                next_poll = 0                                # fresh device states on show

        if state == "on" and now >= next_poll:
            poll_ha()
            next_poll = now + 30

        if state == "on" and now >= next_render:
            s = collect()
            img = render(s) if page == 0 else render_devices()
            if auto and HA["groups"]:
                page_indicator(ImageDraw.Draw(img), page, (now - page_started) / durations[page])
            show_image(img)
            last_img = img
            next_render = now + OPT["refresh_interval"]
            print(
                f"CPU={s['cpu']:.1f}% RAM={s['ram']:.1f}% TEMP={s['temp']:.1f}C "
                f"LOAD={s['load']:.2f} IP={s['ip']} UP={s['uptime']} "
                f"ROUTE={'yes' if s['route'] else 'no'} PAGE={page} "
                f"HEALTH={health()[0]} UPD={HA['updates']}",
                flush=True,
            )

        elif state == "on" and auto and HA["groups"] and last_img is not None:
            # Between full redraws, only refresh the page indicator
            page_indicator(ImageDraw.Draw(last_img), page, (now - page_started) / durations[page])
            show_image(last_img, INDICATOR_BOX)

        if now >= next_publish:
            publish_status(state)
            next_publish = now + 60

        time.sleep(1)


if __name__ == "__main__":
    main()
