"""Generates the LinkedIn carousel for Facet.

Matches the visual language of the Beam carousel (part 1 of the series):
2400x3000, dark gradient, numbered series badge, oversized headline with a
muted second line, pill tags, and a footer lockup.
"""
import os
from PIL import Image, ImageDraw, ImageFont

W, H = 2400, 3000
OUT = "docs/social"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
os.makedirs(OUT, exist_ok=True)

BG_TOP, BG_BOT = (12, 13, 18), (20, 18, 32)
WHITE = (243, 243, 247)
GREY = (138, 140, 155)
DIM = (96, 98, 112)
ACCENT = (124, 122, 255)
ACCENT_2 = (162, 122, 255)

NEUE = "/System/Library/Fonts/HelveticaNeue.ttc"
# HelveticaNeue.ttc face indices: 0 Regular, 1 Bold, 10 Medium.
FACE = {"bold": 1, "regular": 0, "medium": 10}
def f(size, bold=True, weight=None):
    return ImageFont.truetype(NEUE, size, index=FACE[weight or ("bold" if bold else "regular")])

def backdrop():
    img = Image.new("RGB", (W, H), BG_TOP)
    d = ImageDraw.Draw(img)
    for y in range(H):
        t = y / H
        d.line([(0, y), (W, y)],
               fill=tuple(int(BG_TOP[i] + (BG_BOT[i] - BG_TOP[i]) * t) for i in range(3)))
    # soft accent bloom, top-left
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    for r in range(760, 0, -20):
        a = int(16 * (1 - r / 760))
        gd.ellipse([280 - r, 210 - r, 280 + r, 210 + r], fill=(110, 90, 255, a))
    return Image.alpha_composite(img.convert("RGBA"), glow).convert("RGB")

def wrap(draw, text, font, max_w):
    words, lines, cur = text.split(), [], ""
    for w_ in words:
        trial = (cur + " " + w_).strip()
        if draw.textlength(trial, font=font) <= max_w:
            cur = trial
        else:
            if cur: lines.append(cur)
            cur = w_
    if cur: lines.append(cur)
    return lines

def badge(d, n, label):
    bf, lf = f(46), f(44)
    pill_w, pill_h = 132, 74
    x, y = 180, 190
    d.rounded_rectangle([x, y, x + pill_w, y + pill_h], radius=37, fill=ACCENT)
    tw = d.textlength(n, font=bf)
    d.text((x + (pill_w - tw) / 2, y + 11), n, font=bf, fill=(10, 10, 16))
    # letterspaced label
    lx = x + pill_w + 46
    for ch in label.upper():
        d.text((lx, y + 14), ch, font=lf, fill=ACCENT)
        lx += d.textlength(ch, font=lf) + 9

def icon(img, size=250, pos=(180, 700)):
    try:
        ic = Image.open("build/icon_preview.png").convert("RGBA").resize((size, size), Image.LANCZOS)
    except FileNotFoundError:
        return
    glow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    cx, cy = pos[0] + size // 2, pos[1] + size // 2
    for r in range(int(size * 1.15), 0, -12):
        a = int(30 * (1 - r / (size * 1.15)))
        gd.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(120, 100, 255, a))
    img.alpha_composite(glow)
    img.alpha_composite(ic, pos)

def tags(d, items, y):
    x = 180
    tf = f(50, weight="regular")
    for t in items:
        tw = d.textlength(t, font=tf)
        w_ = tw + 86
        d.rounded_rectangle([x, y, x + w_, y + 104], radius=52,
                            fill=(30, 31, 42), outline=(52, 54, 70), width=2)
        d.text((x + 43, y + 24), t, font=tf, fill=GREY)
        x += w_ + 28

def footer(d, img, right="Free & open source"):
    d.line([(180, H - 300), (W - 180, H - 300)], fill=(46, 47, 62), width=3)
    try:
        ic = Image.open("build/icon_preview.png").convert("RGBA").resize((96, 96), Image.LANCZOS)
        img.alpha_composite(ic, (180, H - 236))
    except FileNotFoundError:
        pass
    d.text((300, H - 218), "Facet", font=f(62), fill=GREY)
    rf, rb = f(56, weight="regular"), f(56)
    pre, strong = right.rsplit(" ", 1) if " " in right else (right, "")
    wpre, wstr = d.textlength(pre + " ", font=rf), d.textlength(strong, font=rb)
    d.text((W - 180 - wpre - wstr, H - 214), pre + " ", font=rf, fill=DIM)
    d.text((W - 180 - wstr, H - 214), strong, font=rb, fill=GREY)

def slide(n, label, head_white, head_grey, body, tag_items=None,
          show_icon=True, body_color=GREY, accent_line=None):
    img = backdrop().convert("RGBA")
    d = ImageDraw.Draw(img)
    badge(d, n, label)
    if show_icon:
        icon(img, pos=(180, 660))
        y = 1010
    else:
        y = 780

    hf = f(150)
    for ln in wrap(d, head_white, hf, W - 360):
        d.text((180, y), ln, font=hf, fill=WHITE); y += 178
    if head_grey:
        for ln in wrap(d, head_grey, hf, W - 360):
            d.text((180, y), ln, font=hf, fill=(108, 110, 128)); y += 178

    y += 60
    bf = f(64, weight="regular")
    for ln in wrap(d, body, bf, W - 420):
        d.text((180, y), ln, font=bf, fill=body_color); y += 92

    if accent_line:
        y += 46
        af = f(72)
        for ln in wrap(d, accent_line, af, W - 420):
            d.text((180, y), ln, font=af, fill=ACCENT_2); y += 100

    if tag_items:
        tags(d, tag_items, min(y + 80, H - 560))
    footer(d, img)
    return img.convert("RGB")

SLIDES = [
    dict(n="01", label="Build it myself",
         head_white="Finding one person meant scrolling.",
         head_grey="So I built my own.",
         body="3,273 photos sitting in folders on my Mac, and no way to find "
              "every shot of one person.",
         tag_items=["macOS", "On-device", "Open source"]),
    dict(n="02", label="The problem", show_icon=False,
         head_white="Every option wanted something.",
         head_grey="",
         body="Apple Photos only groups faces inside its own library — my folders were "
              "invisible to it. Google Photos wanted the upload. Immich and PhotoPrism "
              "wanted Docker, a database and a server to babysit.\n\n"
              "I just wanted to point something at a folder.",
         tag_items=None),
    dict(n="03", label="What it does", show_icon=False,
         head_white="It finds every face and groups them into people.",
         head_grey="",
         body="Name someone once. Every new photo of them joins that group automatically.",
         accent_line="No tagging. No sorting. No work."),
    dict(n="04", label="What it does", show_icon=False,
         head_white="Click a face. Get every photo of them.",
         head_grey="",
         body="Open any photo, tap the box around someone's face, and the whole library "
              "filters to that person. Combine two people to find shots of them together.",
         accent_line="Or: everyone except this person."),
    dict(n="05", label="What it does", show_icon=False,
         head_white="Search by typing what's in the photo.",
         head_grey="",
         body="“beach sunset”. “birthday cake”. “dog in snow”. No tags, no albums, no "
              "filenames. It understands the picture itself.",
         tag_items=["Plain English", "Instant"]),
    dict(n="06", label="Remote access", show_icon=False,
         head_white="And it's on your phone. From anywhere.",
         head_grey="",
         body="Your Mac serves a small web app over your own private network. Family get "
              "their own logins and can browse and download — but never delete. That isn't "
              "a setting; the web side has no write endpoints at all.",
         accent_line="Not one photo touches someone else's server."),
    dict(n="07", label="Measured, not claimed", show_icon=False,
         head_white="99.32%",
         head_grey="on the LFW face benchmark.",
         body="I tested the whole pipeline against the standard face-verification "
              "benchmark instead of guessing. ~250 images/sec on Apple Silicon — a "
              "100,000-photo library indexes in minutes.",
         tag_items=["Vision", "ArcFace", "MobileCLIP"]),
    dict(n="08", label="Free & open source", show_icon=True,
         head_white="Try it.",
         head_grey="",
         body="Download the Mac app, or read every line of it.\n\n"
              "github.com/VigneshDev16/facet\n\n"
              "Part 3 of the series: building real solutions to problems I actually run into.",
         body_color=(186, 188, 204)),
]

def render_multiline(cfg):
    """Body strings may carry explicit blank lines; render them faithfully."""
    parts = cfg["body"].split("\n\n")
    cfg = dict(cfg)
    cfg["body"] = parts[0]
    img = slide(**cfg)
    if len(parts) > 1:
        d = ImageDraw.Draw(img)
        bf = f(64, weight="regular")
        # place continuation under the first block
        y = 0
        # recompute: find a safe y by measuring the first block again
        tmp = ImageDraw.Draw(Image.new("RGB", (10, 10)))
        head_lines = len(wrap(tmp, cfg["head_white"], f(150), W - 360)) + \
                     (len(wrap(tmp, cfg["head_grey"], f(150), W - 360)) if cfg.get("head_grey") else 0)
        y = (1010 if cfg.get("show_icon", True) else 780) + head_lines * 178 + 60
        y += len(wrap(tmp, parts[0], bf, W - 420)) * 92 + 40
        for block in parts[1:]:
            for ln in wrap(d, block, bf, W - 420):
                d.text((180, y), ln, font=bf, fill=cfg.get("body_color", GREY)); y += 92
            y += 40
    return img

pages = []
for cfg in SLIDES:
    img = render_multiline(cfg)
    p = f"{OUT}/facet-slide-{cfg['n']}.png"
    img.save(p, quality=95)
    pages.append(img)
    print("wrote", p)

pages[0].save(f"{OUT}/Facet-carousel.pdf", save_all=True, append_images=pages[1:],
              resolution=200.0)
print("wrote", f"{OUT}/Facet-carousel.pdf")
