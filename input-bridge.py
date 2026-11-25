#!/usr/bin/env python3
"""evdev -> uinput bridge for the Apple Magic Mouse 1 (dms magicOptions).

Grabs the mouse's evdev node and re-emits it through uinput, applying:
  - two-finger click/tap -> BTN_RIGHT ("twoFinger" = physical click with >=2 fingers,
                                        "twoFingerTap" = touch tap)
  - one-finger tap       -> BTN_LEFT  (when MAGIC_TAP_TO_CLICK=1; physical clicks
                                        from the driver always pass through)
  - 2-finger horizontal swipe -> Alt+Left / Alt+Right (when MAGIC_TWO_FINGER_SWIPE=backForward)
  - 3-finger horizontal swipe -> niri focus-workspace-left/right
  - 4-finger swipe up         -> niri toggle-overview
  - MAGIC_SCROLL_SPEED scales wheel scroll deltas (percent, default 100)

Env: MAGIC_EVDEV (required), MAGIC_RIGHT_CLICK, MAGIC_TAP_TO_CLICK,
     MAGIC_SCROLL_SPEED, MAGIC_TWO_FINGER_SWIPE, MAGIC_THREE_FINGER,
     MAGIC_FOUR_FINGER.
Stdlib only.
"""
import errno
import fcntl
import os
import selectors
import signal
import struct
import subprocess
import sys
import time

# --- ioctl helpers ----------------------------------------------------------
def _IOC(d, t, n, s):
    return (d << 30) | (s << 16) | (ord(t) << 8) | n

def _IOW(t, n, s):
    return _IOC(1, t, n, s)

def _IOR(t, n, s):
    return _IOC(2, t, n, s)

EVIOCGRAB = _IOW('E', 0x90, 4)
EVIOCGID = _IOR('E', 0x02, 8)
EVIOCGPROP = _IOR('E', 0x09, 8)
EVIOCGBIT = lambda ev, ln: _IOR('E', 0x20 + ev, ln)
EVIOCGABS = lambda c: _IOR('E', 0x40 + c, 24)

UI_SET_EVBIT = _IOW('U', 100, 4)
UI_SET_KEYBIT = _IOW('U', 101, 4)
UI_SET_RELBIT = _IOW('U', 102, 4)
UI_SET_ABSBIT = _IOW('U', 103, 4)
UI_SET_MSCBIT = _IOW('U', 104, 4)
UI_SET_LEDBIT = _IOW('U', 105, 4)
UI_SET_SNDBIT = _IOW('U', 106, 4)
UI_SET_SWBIT = _IOW('U', 108, 4)
UI_SET_PROPBIT = _IOW('U', 109, 4)
UI_DEV_CREATE = _IOC(0, 'U', 1, 0)
UI_DEV_DESTROY = _IOC(0, 'U', 2, 0)

EV_SYN, EV_KEY, EV_REL, EV_ABS, EV_MSC, EV_SW = 0, 1, 2, 3, 4, 8
EV_LED, EV_SND = 17, 18
SETTERS = {EV_KEY: UI_SET_KEYBIT, EV_REL: UI_SET_RELBIT, EV_ABS: UI_SET_ABSBIT,
           EV_MSC: UI_SET_MSCBIT, EV_SW: UI_SET_SWBIT, EV_LED: UI_SET_LEDBIT,
           EV_SND: UI_SET_SNDBIT}
ABS_CNT = 0x40
BUS_VIRTUAL = 0x06

EVENT = struct.Struct("<qqHHi")
UINPUT_DEV = struct.Struct("=80sHHHHI" + "64i" * 4)

BTN_LEFT, BTN_RIGHT, BTN_MIDDLE = 0x110, 0x111, 0x112
BTN_MOUSE_MIN, BTN_MOUSE_MAX = 0x110, 0x11f
KEY_LEFTALT, KEY_LEFT, KEY_RIGHT = 0x38, 0x69, 0x6A
SYN_REPORT = 0
ABS_MT_SLOT, ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_TRACKING_ID = 0x2F, 0x35, 0x36, 0x39
REL_HWHEEL, REL_WHEEL, REL_WHEEL_HI_RES, REL_HWHEEL_HI_RES = 0x06, 0x08, 0x0b, 0x0c
SCROLL_REL_CODES = (REL_HWHEEL, REL_WHEEL, REL_WHEEL_HI_RES, REL_HWHEEL_HI_RES)


def niri(action):
    try:
        subprocess.run(["niri", "msg", "action", action],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
    except Exception:
        pass


def set_bits_from(src_fd, dst_fd, ev_max):
    """Clone pointer/relative capability bits (without EV_ABS or keyboard keys) from src_fd."""
    evbits = bytearray(8)
    fcntl.ioctl(src_fd, EVIOCGBIT(0, len(evbits)), evbits, True)
    rel_codes = set()
    for ev in range(0, ev_max + 1):
        if not (evbits[ev // 8] >> (ev % 8)) & 1:
            continue
        # EV_SYN is implicit; EV_ABS is consumed for gestures only so the virtual
        # pointer never exposes touch axes that require libinput quirks to disable.
        if ev in (EV_SYN, EV_ABS):
            continue
        fcntl.ioctl(dst_fd, UI_SET_EVBIT, ev)
        setter = SETTERS.get(ev)
        if setter:
            ln = 96 if ev == EV_KEY else 24
            bits = bytearray(ln)
            fcntl.ioctl(src_fd, EVIOCGBIT(ev, ln), bits, True)
            for byte_i, b in enumerate(bits):
                for bit in range(8):
                    if (b >> bit) & 1:
                        code = byte_i * 8 + bit
                        if ev == EV_KEY and not (BTN_MOUSE_MIN <= code <= BTN_MOUSE_MAX):
                            continue
                        fcntl.ioctl(dst_fd, setter, code)
                        if ev == EV_REL:
                            rel_codes.add(code)
    # properties (buttonpad etc.)
    props = bytearray(8)
    fcntl.ioctl(src_fd, EVIOCGPROP, props, True)
    for byte_i, b in enumerate(props):
        for bit in range(8):
            if (b >> bit) & 1:
                fcntl.ioctl(dst_fd, UI_SET_PROPBIT, byte_i * 8 + bit)
    return rel_codes


def create_uinput_device(name, bustype, vendor, product, version, setup_fn):
    """Create and configure a uinput virtual device."""
    ufd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    try:
        zeros = [0] * ABS_CNT
        udev = UINPUT_DEV.pack(name.ljust(80, b"\0"), bustype, vendor, product, version, 0,
                               *zeros, *zeros, *zeros, *zeros)
        os.write(ufd, udev)
        result = setup_fn(ufd)
        fcntl.ioctl(ufd, UI_DEV_CREATE)
        return ufd, result
    except Exception:
        os.close(ufd)
        raise


def destroy_uinput(fd):
    if fd is None:
        return
    try:
        fcntl.ioctl(fd, UI_DEV_DESTROY)
    except OSError:
        pass
    os.close(fd)


def clone_abs_ranges(src_fd):
    absinfo = {}
    for c in range(ABS_CNT):
        buf = bytearray(24)
        try:
            fcntl.ioctl(src_fd, EVIOCGABS(c), buf, True)
        except OSError:
            continue
        v, mn, mx, fz, fl, res = struct.unpack("=6i", bytes(buf))
        absinfo[c] = (mn, mx)
    return absinfo


def emit(fd, ev_type, code, value):
    os.write(fd, EVENT.pack(0, 0, ev_type, code, value))


def make_scroll_normalizer(scroll_speed, has_wheel_hr, has_hwheel_hr):
    """Return a per-frame EV_REL emitter with hi-res fallback and speed scaling."""
    scale = max(10, scroll_speed) / 100.0
    # Per axis state: [has_hr, hi_code, last_hr_ts, last_hr_sign, hr_rem, lo_rem]
    axes = {
        REL_WHEEL: [has_wheel_hr, REL_WHEEL_HI_RES, 0.0, 0, 0.0, 0.0],
        REL_HWHEEL: [has_hwheel_hr, REL_HWHEEL_HI_RES, 0.0, 0, 0.0, 0.0],
    }

    def emit_frame(ufd, frame_rel):
        now = time.monotonic()
        codes = {c for c, _ in frame_rel}
        emitted = False
        for code, value in frame_rel:
            if code not in SCROLL_REL_CODES:
                emit(ufd, EV_REL, code, value)
                emitted = True
        for lo_code, cfg in axes.items():
            has_hr, hi_code, last_ts, last_sign, hr_rem, lo_rem = cfg
            if has_hr:
                if hi_code in codes:
                    raw_hr = sum(v for c, v in frame_rel if c == hi_code)
                    if raw_hr:
                        cfg[2] = now
                        cfg[3] = 1 if raw_hr > 0 else -1
                elif lo_code in codes:
                    lo_in = sum(v for c, v in frame_rel if c == lo_code)
                    lo_sign = (1 if lo_in > 0 else -1) if lo_in else 0
                    # hid_magicmouse steps 224 vs 10*22 can fire an out-of-phase lo-res tick
                    # right after hi-res events already emitted the full detent; drop it so
                    # we neither spike +120 nor trigger libinput's low-res hires error.
                    if lo_sign and lo_sign == last_sign and (now - last_ts) < 0.25:
                        raw_hr = 0
                    else:
                        raw_hr = lo_in * 120
                else:
                    raw_hr = 0
                if not raw_hr:
                    continue
                if hr_rem and (raw_hr > 0) != (hr_rem > 0):
                    hr_rem = lo_rem = 0.0
                    cfg[4] = cfg[5] = 0.0
                total_hr = hr_rem + raw_hr * scale
                emit_hr = int(total_hr)
                cfg[4] = total_hr - emit_hr
                if emit_hr:
                    new_lo = lo_rem + emit_hr
                    emit_lo = int(new_lo / 120)
                    cfg[5] = new_lo - emit_lo * 120
                    if emit_lo:
                        emit(ufd, EV_REL, lo_code, emit_lo)
                    emit(ufd, EV_REL, hi_code, emit_hr)
                    emitted = True
            elif lo_code in codes:
                lo_in = sum(v for c, v in frame_rel if c == lo_code)
                if not lo_in:
                    continue
                if lo_rem and (lo_in > 0) != (lo_rem > 0):
                    lo_rem = cfg[5] = 0.0
                total_lo = lo_rem + lo_in * scale
                emit_lo = int(total_lo)
                cfg[5] = total_lo - emit_lo
                if emit_lo:
                    emit(ufd, EV_REL, lo_code, emit_lo)
                    emitted = True
        return emitted

    return emit_frame


def tap(fd, code):
    emit(fd, EV_KEY, code, 1)
    emit(fd, EV_SYN, SYN_REPORT, 0)
    emit(fd, EV_KEY, code, 0)
    emit(fd, EV_SYN, SYN_REPORT, 0)


def alt_arrow(fd, code):
    """Alt+Left / Alt+Right: browser/app back and forward."""
    emit(fd, EV_KEY, KEY_LEFTALT, 1)
    emit(fd, EV_SYN, SYN_REPORT, 0)
    tap(fd, code)
    emit(fd, EV_KEY, KEY_LEFTALT, 0)
    emit(fd, EV_SYN, SYN_REPORT, 0)


def main():
    dev = os.environ.get("MAGIC_EVDEV", "")
    right_click = os.environ.get("MAGIC_RIGHT_CLICK", "twoFinger")
    tap_to_click = os.environ.get("MAGIC_TAP_TO_CLICK", "0") == "1"
    try:
        scroll_speed = int(float(os.environ.get("MAGIC_SCROLL_SPEED", "100")))
    except ValueError:
        scroll_speed = 100
    three = os.environ.get("MAGIC_THREE_FINGER", "off")
    four = os.environ.get("MAGIC_FOUR_FINGER", "off")
    two_swipe = os.environ.get("MAGIC_TWO_FINGER_SWIPE", "backForward")
    if not dev:
        sys.exit("MAGIC_EVDEV not set")

    def _stop(*_):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    src = os.open(dev, os.O_RDWR | os.O_NONBLOCK)
    ufd = kfd = None
    sel = selectors.DefaultSelector()
    try:
        fcntl.ioctl(src, EVIOCGRAB, 1)

        idbuf = bytearray(8)
        fcntl.ioctl(src, EVIOCGID, idbuf, True)
        bustype, vendor, product, version = struct.unpack("=4H", bytes(idbuf))
        absinfo = clone_abs_ranges(src)

        ufd, rel_codes = create_uinput_device(
            b"Apple Magic Mouse (dms)",
            bustype, vendor, product, (version + 1) & 0xFFFF,
            lambda fd: set_bits_from(src, fd, 0x1f),
        )

        def setup_keys(fd):
            fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
            for k in (KEY_LEFTALT, KEY_LEFT, KEY_RIGHT):
                fcntl.ioctl(fd, UI_SET_KEYBIT, k)

        kfd, _ = create_uinput_device(
            b"Apple Magic Mouse Keys (dms)",
            BUS_VIRTUAL, vendor, product, 1,
            setup_keys,
        )

        emit_rel_frame = make_scroll_normalizer(
            scroll_speed,
            REL_WHEEL_HI_RES in rel_codes,
            REL_HWHEEL_HI_RES in rel_codes,
        )

        x_range = abs(absinfo.get(ABS_MT_POSITION_X, (0, 1))[1] - absinfo.get(ABS_MT_POSITION_X, (0, 0))[0]) or 1
        y_range = abs(absinfo.get(ABS_MT_POSITION_Y, (0, 1))[1] - absinfo.get(ABS_MT_POSITION_Y, (0, 0))[0]) or 1
        swipe_px = 0.25 * min(x_range, y_range)
        tap_px = 0.08 * min(x_range, y_range)

        slots = {}
        cur = 0
        # per-gesture state, reset when all fingers lift; "ends" keeps each finger's
        # first (x0,y0) and last (x,y) position for net-travel computation
        g = {"start": None, "maxslots": 0, "left_seen": False, "ends": {}}

        debug = os.environ.get("MAGIC_DEBUG", "") == "1"

        def finish_gesture():
            if g["start"] is None or g["maxslots"] == 0:
                g.update(start=None, maxslots=0, left_seen=False)
                return
            dur = time.time() - g["start"]
            # net travel per finger from its first to its last position
            dx = sum(s["x"] - s["x0"] for s in g["ends"].values() if s["x0"] is not None)
            dy = sum(s["y"] - s["y0"] for s in g["ends"].values() if s["y0"] is not None)
            moved = max(abs(dx), abs(dy))
            decision = "none"
            if g["maxslots"] >= 2 and dur < 0.4 and moved < tap_px \
                    and right_click == "twoFingerTap" and not g["left_seen"]:
                tap(ufd, BTN_RIGHT)          # two-finger tap = right click
                decision = "BTN_RIGHT"
            elif g["maxslots"] == 2 and two_swipe == "backForward" and abs(dx) > swipe_px:
                alt_arrow(kfd, KEY_RIGHT if dx > 0 else KEY_LEFT)  # trackpad back/forward
                decision = "back/forward"
            elif g["maxslots"] == 1 and dur < 0.3 and moved < tap_px \
                    and tap_to_click and not g["left_seen"]:
                tap(ufd, BTN_LEFT)           # light one-finger tap = click
                decision = "BTN_LEFT(tap)"
            elif g["maxslots"] == 3 and three == "workspace" and abs(dx) > swipe_px:
                niri("focus-workspace-right" if dx > 0 else "focus-workspace-left")
                decision = "workspace"
            elif g["maxslots"] >= 4 and four == "overview" and dy < -swipe_px:
                niri("toggle-overview")
                decision = "overview"
            if debug:
                print(f"gesture slots={g['maxslots']} dur={dur:.2f} dx={dx} dy={dy} "
                      f"moved={moved:.0f} tap_px={tap_px:.0f} swipe_px={swipe_px:.0f} "
                      f"left_seen={g['left_seen']} -> {decision}", flush=True)
            g.update(start=None, maxslots=0, left_seen=False, ends={})

        sel.register(src, selectors.EVENT_READ)
        frame_keys = []
        frame_rel = []
        frame_dirty = False
        btn_remap = {}

        def flush_keys():
            nonlocal frame_dirty
            for code, value in frame_keys:
                if code in (BTN_LEFT, BTN_RIGHT, BTN_MIDDLE):
                    if value == 1:
                        if slots:
                            g["left_seen"] = True  # physical click, not a tap
                        if right_click == "twoFinger":
                            if len(slots) >= 2:
                                out_code = BTN_RIGHT
                            elif code == BTN_RIGHT:
                                out_code = BTN_LEFT  # disable right-side right click; click left instead
                            else:
                                out_code = code
                        elif right_click == "off" and code == BTN_RIGHT:
                            btn_remap[code] = None
                            continue
                        else:
                            out_code = code
                        btn_remap[code] = out_code
                    elif value == 0:
                        out_code = btn_remap.pop(code, code)
                        if out_code is None:
                            continue
                    else:
                        out_code = btn_remap.get(code, code)
                        if out_code is None:
                            continue
                else:
                    out_code = code
                emit(ufd, EV_KEY, out_code, value)
                frame_dirty = True
            frame_keys.clear()

        while True:
            sel.select()
            try:
                chunk = os.read(src, EVENT.size * 64)
            except BlockingIOError:
                continue
            except OSError as exc:
                if exc.errno in (errno.ENODEV, errno.EIO):
                    break
                raise
            if not chunk:
                break
            for off in range(0, len(chunk) - EVENT.size + 1, EVENT.size):
                _, _, ev_type, code, value = EVENT.unpack(chunk[off:off + EVENT.size])
                if ev_type == EV_ABS:
                    if code == ABS_MT_SLOT:
                        cur = value
                    elif code == ABS_MT_TRACKING_ID:
                        if value == -1:
                            if cur in slots:
                                g["ends"][cur] = slots.pop(cur)
                        else:
                            slots[cur] = {"x0": None, "y0": None, "x": 0, "y": 0}
                            if g["start"] is None:
                                g["start"] = time.time()
                        g["maxslots"] = max(g["maxslots"], len(slots))
                    elif code == ABS_MT_POSITION_X and cur in slots:
                        s = slots[cur]
                        if s["x0"] is None:
                            s["x0"] = value
                        s["x"] = value
                    elif code == ABS_MT_POSITION_Y and cur in slots:
                        s = slots[cur]
                        if s["y0"] is None:
                            s["y0"] = value
                        s["y"] = value
                elif ev_type == EV_KEY:
                    frame_keys.append((code, value))
                elif ev_type == EV_REL:
                    frame_rel.append((code, value))
                elif ev_type == EV_SYN and code == SYN_REPORT:
                    if frame_keys:
                        flush_keys()
                    if frame_rel:
                        if emit_rel_frame(ufd, frame_rel):
                            frame_dirty = True
                        frame_rel.clear()
                    if frame_dirty:
                        emit(ufd, EV_SYN, SYN_REPORT, value)
                        frame_dirty = False
                    if not slots:
                        finish_gesture()
                else:
                    emit(ufd, ev_type, code, value)
                    frame_dirty = True
    except KeyboardInterrupt:
        pass
    finally:
        sel.close()
        destroy_uinput(kfd)
        destroy_uinput(ufd)
        try:
            fcntl.ioctl(src, EVIOCGRAB, 0)
        except OSError:
            pass
        os.close(src)


if __name__ == "__main__":
    main()
