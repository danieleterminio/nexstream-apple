"""Draws the Apple asset catalogs for NexStream with Pillow: iOS app icon, tvOS layered icon + Top Shelf images,
the in-app symbol images, colours. Geometry of the mark = tools/brand/brand_png.py of the Android project.
Usage: python scripts/make_assets.py"""
import json, math, os
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SS = 6
STOPS = [(0.0, (0xE5, 0x17, 0x3F)), (0.55, (0xFF, 0x4B, 0x3A)), (1.0, (0xFF, 0x7A, 0x1A))]
FONT = os.path.join(ROOT, 'scripts', 'Sora.ttf')


def lerp(stops, t):
    t = max(0.0, min(1.0, t))
    for (a, ca), (b, cb) in zip(stops, stops[1:]):
        if t <= b:
            k = (t - a) / (b - a) if b > a else 0
            return tuple(round(ca[i] + (cb[i] - ca[i]) * k) for i in range(3))
    return stops[-1][1]


def gradient(w, h, stops, box):
    x0, y0, x1, y1 = box
    small = Image.new('RGB', (64, 64))
    px = small.load()
    for j in range(64):
        for i in range(64):
            x = i / 63 * w
            y = j / 63 * h
            t = (((x - x0) / max(1, x1 - x0)) + ((y - y0) / max(1, y1 - y0))) / 2
            px[i, j] = lerp(stops, t)
    return small.resize((w, h), Image.BILINEAR)


def symbol(size, waves=(255, 255, 255, 255), play=None, parts='both'):
    S = size * SS
    u = S / 100.0
    img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    def arc(cx, cy, r, a0, a1, w):
        box = [(cx - r) * u, (cy - r) * u, (cx + r) * u, (cy + r) * u]
        d.arc(box, a0, a1, fill=waves, width=round(w * u))
        for a in (a0, a1):
            ex = cx + (r - w / 2) * math.cos(math.radians(a))
            ey = cy + (r - w / 2) * math.sin(math.radians(a))
            d.ellipse([(ex - w / 2) * u, (ey - w / 2) * u, (ex + w / 2) * u, (ey + w / 2) * u], fill=waves)

    if parts in ('both', 'waves'):
        arc(39.23, 50, 20 + 3.5, 131.4, 228.6, 7)
        arc(37.84, 50, 31 + 3.5, 134.8, 225.2, 7)
    if parts in ('both', 'play'):
        mask = Image.new('L', (S, S), 0)
        m = ImageDraw.Draw(mask)
        pts = [(40, 24), (79, 50), (40, 76)]
        m.polygon([(x * u, y * u) for x, y in pts], fill=255)
        for (x0, y0), (x1, y1) in zip(pts, pts[1:] + pts[:1]):
            m.line([(x0 * u, y0 * u), (x1 * u, y1 * u)], fill=255, width=round(10 * u))
        for x, y in pts:
            m.ellipse([(x - 5) * u, (y - 5) * u, (x + 5) * u, (y + 5) * u], fill=255)
        if play is None:
            fill = gradient(S, S, STOPS, (35 * u, 19 * u, 84 * u, 81 * u)).convert('RGBA')
        else:
            fill = Image.new('RGBA', (S, S), play)
        img.paste(fill, (0, 0), mask)
    return img.resize((size, size), Image.LANCZOS)


def radial_bg(w, h, inner=(0x23, 0x23, 0x30), outer=(0x0D, 0x0D, 0x12), cx=0.3, cy=0.2, r=0.9):
    small = Image.new('RGB', (96, 96))
    px = small.load()
    for j in range(96):
        for i in range(96):
            dd = math.hypot(i / 95 - cx, j / 95 - cy) / r
            t = min(1.0, dd)
            px[i, j] = tuple(round(inner[k] + (outer[k] - inner[k]) * t) for k in range(3))
    return small.resize((w, h), Image.BICUBIC).convert('RGBA')


def wordmark(cap_px, color=(255, 255, 255, 255)):
    size = 200
    f = ImageFont.truetype(FONT, size)
    try:
        f.set_variation_by_axes([700])
    except Exception:
        pass
    cap = f.getbbox('N')[3] - f.getbbox('N')[1]
    size = round(size * cap_px / cap)
    f = ImageFont.truetype(FONT, size)
    try:
        f.set_variation_by_axes([700])
    except Exception:
        pass
    track = -0.015 * size
    widths = [f.getlength(ch) for ch in 'NEXSTREAM']
    w = round(sum(widths) + track * 8) + 4
    top = f.getbbox('N')[1]
    img = Image.new('RGBA', (w, cap_px + 4), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    x = 0.0
    for ch, cw in zip('NEXSTREAM', widths):
        d.text((x, -top), ch, font=f, fill=color)
        x += cw + track
    return img


def lockup(height):
    sym = symbol(height)
    wm = wordmark(round(height * 0.40))
    gap = round(height * 0.04)
    out = Image.new('RGBA', (height + gap + wm.width, height), (0, 0, 0, 0))
    out.paste(sym, (0, 0), sym)
    out.paste(wm, (height + gap, (height - wm.height) // 2), wm)
    return out


def save(img, path, opaque=False):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    (img.convert('RGB') if opaque else img).save(path)


def write(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(obj, f, indent=2)


INFO = {"author": "xcode", "version": 1}


def colorset(dir_, name, hexrgb, alpha=1.0):
    r, g, b = [int(hexrgb[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    comp = {"red": "%.3f" % r, "green": "%.3f" % g, "blue": "%.3f" % b, "alpha": "%.3f" % alpha}
    write(os.path.join(dir_, name + '.colorset', 'Contents.json'),
          {"colors": [{"idiom": "universal", "color": {"color-space": "srgb", "components": comp}}], "info": INFO})


def imageset(dir_, name, draw):
    """draw(scale) -> image at that scale. Writes 1x/2x/3x universal."""
    images = []
    for s in (1, 2, 3):
        fn = '%s@%dx.png' % (name, s)
        save(draw(s), os.path.join(dir_, name + '.imageset', fn))
        images.append({"idiom": "universal", "filename": fn, "scale": "%dx" % s})
    write(os.path.join(dir_, name + '.imageset', 'Contents.json'), {"images": images, "info": INFO})


def shared(cat):
    write(os.path.join(cat, 'Contents.json'), {"info": INFO})
    colorset(cat, 'AccentColor', 'E5173F')
    colorset(cat, 'LaunchBackground', '0D0D12')
    imageset(cat, 'BrandSymbol', lambda s: symbol(96 * s))
    imageset(cat, 'BrandSymbolWhite', lambda s: symbol(96 * s, play=(255, 255, 255, 255)))
    imageset(cat, 'BrandLockup', lambda s: lockup(96 * s))


# ------------------------------------------------------------------ iOS
ios = os.path.join(ROOT, 'App', 'iOS', 'Assets.xcassets')
shared(ios)
icon = radial_bg(1024, 1024)
s = symbol(680)
icon.paste(s, (172, 172), s)
save(icon, os.path.join(ios, 'AppIcon.appiconset', 'icon-1024.png'), opaque=True)
write(os.path.join(ios, 'AppIcon.appiconset', 'Contents.json'),
      {"images": [{"idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "icon-1024.png"}], "info": INFO})

# ------------------------------------------------------------------ tvOS
tv = os.path.join(ROOT, 'App', 'tvOS', 'Assets.xcassets')
shared(tv)
brand = os.path.join(tv, 'App Icon & Top Shelf Image.brandassets')


def tv_layers(w, h):
    """Three parallax layers: ink background, the white waves, the play in front."""
    back = radial_bg(w, h, inner=(0x26, 0x26, 0x34), outer=(0x0D, 0x0D, 0x12), cx=0.25, cy=0.15, r=1.1)
    size = round(h * 0.86)
    ox = (w - size) // 2
    oy = (h - size) // 2
    mid = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    wv = symbol(size, parts='waves')
    mid.paste(wv, (ox, oy), wv)
    front = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    pl = symbol(size, parts='play')
    front.paste(pl, (ox, oy), pl)
    return [('Front', front, False), ('Middle', mid, False), ('Back', back, True)]


def imagestack(name, w, h, scales):
    d = os.path.join(brand, name + '.imagestack')
    write(os.path.join(d, 'Contents.json'),
          {"layers": [{"filename": n + '.imagestacklayer'} for n in ('Front', 'Middle', 'Back')], "info": INFO})
    for sc in scales:
        for lname, img, opaque in tv_layers(w * sc, h * sc):
            ld = os.path.join(d, lname + '.imagestacklayer')
            write(os.path.join(ld, 'Contents.json'), {"info": INFO})
            fn = '%s@%dx.png' % (lname.lower(), sc)
            save(img, os.path.join(ld, 'Content.imageset', fn), opaque=opaque)
    for lname in ('Front', 'Middle', 'Back'):
        images = [{"idiom": "tv", "filename": '%s@%dx.png' % (lname.lower(), sc), "scale": "%dx" % sc} for sc in scales]
        write(os.path.join(d, lname + '.imagestacklayer', 'Content.imageset', 'Contents.json'), {"images": images, "info": INFO})


imagestack('App Icon', 400, 240, (1, 2))
imagestack('App Icon - App Store', 1280, 768, (1,))


def topshelf(name, w, h):
    d = os.path.join(brand, name + '.imageset')
    images = []
    for sc in (1, 2):
        img = radial_bg(w * sc, h * sc, inner=(0x1F, 0x1F, 0x2B), outer=(0x0D, 0x0D, 0x12), cx=0.2, cy=0.1, r=1.3)
        lk = lockup(260 * sc)
        img.paste(lk, ((w * sc - lk.width) // 2, (h * sc - lk.height) // 2), lk)
        fn = 'shelf@%dx.png' % sc
        save(img, os.path.join(d, fn), opaque=True)
        images.append({"idiom": "tv", "filename": fn, "scale": "%dx" % sc})
    write(os.path.join(d, 'Contents.json'), {"images": images, "info": INFO})


topshelf('Top Shelf Image', 1920, 720)
topshelf('Top Shelf Image Wide', 2320, 720)
write(os.path.join(brand, 'Contents.json'), {"assets": [
    {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
    {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
    {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
    {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
], "info": INFO})
print('assets written')
