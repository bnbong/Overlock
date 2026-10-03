#!/usr/bin/env python3
"""Overlock one-page poster (docs/promo/overlock_onepager.png, 1200 px wide).

The layout follows the earlier hand-made poster: a header with the menu backdrop and the
logo, cream cards with dashed Thread Purple borders that hold in-game screenshots, a
CONTROLS card with drawn keycaps, and the hero illustration as the footer. Every
screenshot comes from docs/promo/screenshots/ (tools/promo/onepager/screenshots.py).

usage: make_onepager.py [--out PATH]
Needs Pillow and numpy (the promo video venv has both).
"""
import argparse
import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
FONTS = os.path.join(ROOT, "tools", "promo", "fonts")
GFX = os.path.join(ROOT, "game", "assets", "gfx")
PROMO = os.path.join(ROOT, "docs", "promo")
SHOTS = os.path.join(PROMO, "screenshots")

W = 1200
PURPLE = (0x8D, 0x62, 0xB9)
PLUM = (0x2A, 0x18, 0x38)
CREAM = (0xF3, 0xE7, 0xC9)
RED = (0xE5, 0x36, 0x4B)
INK = (0x47, 0x34, 0x2A)
BODY = (0xEF, 0xE3, 0xC8)       # page background (slightly darker than the cards)
CARD = (0xF8, 0xEF, 0xDA)       # card fill

# ---------------------------------------------------------------- content (keep in sync with docs/promo/press.md)
SUBTITLE = "~재봉틀 레이싱~"
TAGLINE = "원단 위 손떨리는 경주"
ONE_LINER = "재봉틀 노루발을 몰아 원단 위 재봉선을 정확히 박는 웹 타임어택 게임"
FEATURES = [
    ("조작은 두 가지", "속도 단계와 방향, 꼭짓점은 드리프트"),
    ("정직하게 박을수록", "재봉선을 정확히 따라갈수록 높은 등급(S~D)"),
    ("아이템 슬롯", "골무·엄마 찬스를 담았다가 Space로 사용"),
    ("원단별 주행 특성", "면·데님·실크 등 8종, 속도와 반응이 달라요"),
    ("개인 고스트", "내 최고 기록과 나란히 달리기"),
    ("트랙 에디터 · 공유 허브", "직접 그린 코스를 올리고 내려받기"),
]
FEATURE_FOOT = "공식 트랙 15개 · 온라인 리더보드 · 고속 급조향 시 손가락 부상 주의"
BIG = ("gameplay_fold.png", "드리프트하면 손끝 앞에서 원단이 접혀 올라와요")
GRID = [
    ("gameplay_ghost.png", "내 최고 기록이 고스트로 함께 달려요"),
    ("gameplay_bandage.png", "너무 급하게 꺾으면 손가락 부상!"),
    ("finish_zoomout.png", "완주하면 줌아웃, 정직할수록 높은 등급"),
    ("editor.png", "에디터로 코스를 그리고 아이템까지 배치"),
]
STRIP = ("track_kind.png", (96, 170, 1184, 470), "공식 트랙 15개, 또는 직접 만들거나 허브에서 받은 유저 트랙")
CONTROLS = [
    (["<", ">"], ["A", "D"], "조향 (방향)"),
    (["^", "v"], ["W", "S"], "속도 단계"),
    (["Shift"], [], "피벗 드리프트 (홀드)"),
    (["Space"], [], "아이템 사용"),
    (["R", "Esc"], [], "재시작 · 일시정지"),
]
MOBILE = "모바일: 화면의 터치 버튼으로 조작  (조향 ◀ ▶ · 속도 ▲ ▼ · DRIFT · USE)"
GO = "레이싱 ㄱㄱ"
URL = "overlock.bnbong.com"
GITHUB = "GitHub  github.com/bnbong/Overlock"
NOTICE = ("『용과 같이』 시리즈 재봉 미니게임 오마주의 비공식 팬 프로젝트"
          "(SEGA와 무관, 에셋 오리지널·일부 AI 생성).")


def font(weight, size):
    return ImageFont.truetype(os.path.join(FONTS, "Pretendard-%s.otf" % weight), size)


def text_w(d, s, f):
    return d.textlength(s, font=f)


def cover(im, w, h, ay=0.5):
    """Scale to cover w x h and crop (vertical anchor ay)."""
    s = max(w / im.width, h / im.height)
    im = im.resize((round(im.width * s), round(im.height * s)), Image.LANCZOS)
    x = (im.width - w) // 2
    y = int((im.height - h) * ay)
    return im.crop((x, y, x + w, y + h))


def dashed_rrect(d, box, r, color, width=3, dash=14, gap=9):
    """Dashed rounded rectangle (stitch line)."""
    x0, y0, x1, y1 = box
    segs = []
    import math
    # straight edges
    segs += [((x0 + r, y0), (x1 - r, y0)), ((x1, y0 + r), (x1, y1 - r)),
             ((x1 - r, y1), (x0 + r, y1)), ((x0, y1 - r), (x0, y0 + r))]
    pts = []
    for (a, b) in segs:
        pts.append((a, b))
    for (ax, ay), (bx, by) in pts:
        L = math.hypot(bx - ax, by - ay)
        n = int(L // (dash + gap))
        if n <= 0:
            continue
        off = (L - n * (dash + gap) + gap) / 2
        for i in range(n):
            t0 = (off + i * (dash + gap)) / L
            t1 = (off + i * (dash + gap) + dash) / L
            d.line([(ax + (bx - ax) * t0, ay + (by - ay) * t0), (ax + (bx - ax) * t1, ay + (by - ay) * t1)],
                   fill=color, width=width)
    # corner arcs as short dashes
    for cx, cy, a0 in ((x1 - r, y0 + r, 270), (x1 - r, y1 - r, 0), (x0 + r, y1 - r, 90), (x0 + r, y0 + r, 180)):
        d.arc((cx - r, cy - r, cx + r, cy + r), a0 + 20, a0 + 70, fill=color, width=width)


def shadow_card(page, box, radius=26, fill=CARD, border=PURPLE):
    x0, y0, x1, y1 = box
    sh = Image.new("RGBA", page.size, (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle((x0 + 4, y0 + 10, x1 + 4, y1 + 12), radius, fill=(60, 36, 20, 70))
    sh = sh.filter(ImageFilter.GaussianBlur(10))
    page.alpha_composite(sh)
    d = ImageDraw.Draw(page)
    d.rounded_rectangle(box, radius, fill=fill, outline=(0xD9, 0xC8, 0xA6), width=2)
    dashed_rrect(d, (x0 + 10, y0 + 10, x1 - 10, y1 - 10), radius - 8, border, width=3)


def paste_shot(page, img, box, radius=14):
    x0, y0, x1, y1 = box
    img = cover(img.convert("RGB"), x1 - x0, y1 - y0)
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, img.width - 1, img.height - 1), radius, fill=255)
    page.paste(img, (x0, y0), mask)


def centered(d, cx, y, s, f, fill, stroke=0, stroke_fill=None):
    d.text((cx - text_w(d, s, f) / 2, y), s, font=f, fill=fill, stroke_width=stroke, stroke_fill=stroke_fill)


def keycap(page, x, y, label, h=58):
    d = ImageDraw.Draw(page)
    f = font("Medium", 26 if len(label) > 1 else 30)
    if label in ("<", ">", "^", "v"):
        w = h
    else:
        w = max(h, int(text_w(d, label, f)) + 40)
    d.rounded_rectangle((x, y + 5, x + w, y + h + 5), 12, fill=(0x9C, 0x86, 0x68))
    d.rounded_rectangle((x, y, x + w, y + h), 12, fill=(0xFB, 0xF5, 0xE6), outline=(0x5A, 0x48, 0x3A), width=3)
    cx, cy = x + w / 2, y + h / 2
    tri = {"<": [(cx + 10, cy - 13), (cx + 10, cy + 13), (cx - 13, cy)],
           ">": [(cx - 10, cy - 13), (cx - 10, cy + 13), (cx + 13, cy)],
           "^": [(cx - 13, cy + 10), (cx + 13, cy + 10), (cx, cy - 13)],
           "v": [(cx - 13, cy - 10), (cx + 13, cy - 10), (cx, cy + 13)]}
    if label in tri:
        d.polygon(tri[label], fill=(0x3A, 0x2C, 0x24))
    else:
        bb = d.textbbox((0, 0), label, font=f)
        d.text((cx - (bb[2] - bb[0]) / 2 - bb[0], cy - (bb[3] - bb[1]) / 2 - bb[1]), label, font=f, fill=(0x3A, 0x2C, 0x24))
    return w


def section_title(d, cx, y, s):
    f = font("SemiBold", 24)
    spaced = " ".join(s)
    centered(d, cx, y, spaced, f, PURPLE)


def build():
    parts = []  # (height, draw_fn) assembled top to bottom
    page = Image.new("RGBA", (W, 4400), BODY + (255,))
    d = ImageDraw.Draw(page)

    # ---------------- header
    HH = 560
    bg = cover(Image.open(os.path.join(GFX, "menu_bg.png")), W, HH, 0.35).convert("RGBA")
    page.paste(bg, (0, 0))
    grad = Image.new("RGBA", (W, HH), (0, 0, 0, 0))
    gd = ImageDraw.Draw(grad)
    for yy in range(HH):
        a = int(150 * max(0.0, (yy - HH * 0.35) / (HH * 0.65)) ** 1.3)
        gd.line([(0, yy), (W, yy)], fill=PLUM + (a,))
    page.alpha_composite(grad)
    logo = Image.open(os.path.join(GFX, "overlock_logo.png")).convert("RGBA")
    lw = 600
    logo = logo.resize((lw, round(logo.height * lw / logo.width)), Image.LANCZOS)
    page.alpha_composite(logo, ((W - lw) // 2, 28))
    d = ImageDraw.Draw(page)
    centered(d, W / 2, 330, SUBTITLE, font("ExtraBold", 62), CREAM, 4, PLUM)
    centered(d, W / 2, 412, TAGLINE, font("SemiBold", 32), CREAM, 3, PLUM)
    # one-liner band
    f = font("Medium", 25)
    bw = text_w(d, ONE_LINER, f) + 56
    d.rounded_rectangle(((W - bw) / 2, 478, (W + bw) / 2, 528), 25, fill=PLUM + (235,))
    dashed_rrect(d, ((W - bw) / 2 + 6, 484, (W + bw) / 2 - 6, 522), 19, RED, width=2, dash=10, gap=7)
    centered(d, W / 2, 487, ONE_LINER, f, CREAM)
    y = HH + 34

    # ---------------- features
    fh = 3 * 92 + 150
    shadow_card(page, (60, y, W - 60, y + fh))
    d = ImageDraw.Draw(page)
    section_title(d, W / 2, y + 30, "FEATURES")
    colx = [104, 620]
    for i, (head, body) in enumerate(FEATURES):
        cx = colx[i % 2]
        cy = y + 82 + (i // 2) * 92
        d.ellipse((cx, cy + 9, cx + 16, cy + 25), fill=PURPLE)
        d.ellipse((cx + 4, cy + 13, cx + 12, cy + 21), fill=CARD)
        d.text((cx + 30, cy), head, font=font("Bold", 29), fill=INK)
        d.text((cx + 30, cy + 40), body, font=font("Medium", 22), fill=(0x6A, 0x56, 0x48))
    centered(d, W / 2, y + fh - 58, FEATURE_FOOT, font("Medium", 22), PURPLE)
    y += fh + 34

    # ---------------- big screenshot
    iw = W - 120 - 48
    ih = round(iw * 9 / 16)
    bh = ih + 24 + 70
    shadow_card(page, (60, y, W - 60, y + bh))
    paste_shot(page, Image.open(os.path.join(SHOTS, BIG[0])), (84, y + 24, 84 + iw, y + 24 + ih))
    d = ImageDraw.Draw(page)
    centered(d, W / 2, y + 24 + ih + 18, BIG[1], font("Medium", 28), INK)
    y += bh + 30

    # ---------------- 2x2 grid
    cw = (W - 120 - 30) // 2
    siw = cw - 40
    sih = round(siw * 9 / 16)
    ch = sih + 20 + 62
    for i, (fn, cap) in enumerate(GRID):
        cx0 = 60 + (i % 2) * (cw + 30)
        cy0 = y + (i // 2) * (ch + 28)
        shadow_card(page, (cx0, cy0, cx0 + cw, cy0 + ch), radius=22)
        paste_shot(page, Image.open(os.path.join(SHOTS, fn)), (cx0 + 20, cy0 + 20, cx0 + 20 + siw, cy0 + 20 + sih), 10)
        d = ImageDraw.Draw(page)
        fcap = font("Medium", 23)
        centered(d, cx0 + cw / 2, cy0 + 20 + sih + 16, cap, fcap, INK)
    y += 2 * ch + 28 + 30

    # ---------------- strip (track kind select, cropped)
    src = Image.open(os.path.join(SHOTS, STRIP[0])).convert("RGB").crop(STRIP[1])
    siw = W - 120 - 48
    sih = round(siw * src.height / src.width)
    sh_ = sih + 24 + 66
    shadow_card(page, (60, y, W - 60, y + sh_))
    paste_shot(page, src, (84, y + 24, 84 + siw, y + 24 + sih))
    d = ImageDraw.Draw(page)
    centered(d, W / 2, y + 24 + sih + 16, STRIP[2], font("Medium", 26), INK)
    y += sh_ + 34

    # ---------------- controls
    rows = len(CONTROLS)
    kh = rows * 74 + 160
    shadow_card(page, (60, y, W - 60, y + kh))
    d = ImageDraw.Draw(page)
    section_title(d, W / 2, y + 30, "CONTROLS")
    for r, (keys, alt, label) in enumerate(CONTROLS):
        ry = y + 82 + r * 74
        x = 210
        for k in keys:
            x += keycap(page, x, ry, k) + 12
        if alt:
            d = ImageDraw.Draw(page)
            d.text((x + 6, ry + 14), "또는", font=font("Medium", 22), fill=(0x6A, 0x56, 0x48))
            x += 70
            for k in alt:
                x += keycap(page, x, ry, k) + 12
        d = ImageDraw.Draw(page)
        d.text((690, ry + 10), label, font=font("Medium", 30), fill=INK)
    centered(d, W / 2, y + kh - 66, MOBILE, font("Medium", 23), PURPLE)
    y += kh + 40

    # ---------------- footer (hero illustration + url)
    FH = 560
    hero = cover(Image.open(os.path.join(PROMO, "ovelock_hero.png")), W, FH, 0.42).convert("RGBA")
    # fade the top edge into the page colour
    fade = Image.new("L", (W, FH), 255)
    fd = ImageDraw.Draw(fade)
    for yy in range(90):
        fd.line([(0, yy), (W, yy)], fill=int(255 * (yy / 90) ** 1.5))
    base = Image.new("RGBA", (W, FH), BODY + (255,))
    base.paste(hero, (0, 0), fade)
    page.paste(base, (0, y))
    band = Image.new("RGBA", (W, 250), (0, 0, 0, 0))
    bd = ImageDraw.Draw(band)
    for yy in range(250):
        bd.line([(0, yy), (W, yy)], fill=PLUM + (int(225 * min(1.0, yy / 120)),))
    page.alpha_composite(band, (0, y + FH - 250))
    d = ImageDraw.Draw(page)
    fy = y + FH - 172
    f1 = font("Bold", 46)
    f2 = font("ExtraBold", 50)
    tri_w = 34
    total = text_w(d, GO, f1) + 22 + tri_w + 18 + text_w(d, URL, f2)
    x = (W - total) / 2
    d.text((x, fy + 4), GO, font=f1, fill=CREAM, stroke_width=3, stroke_fill=PLUM)
    x += text_w(d, GO, f1) + 22
    d.polygon([(x, fy + 14), (x, fy + 56), (x + tri_w, fy + 35)], fill=CREAM)
    x += tri_w + 18
    d.text((x, fy), URL, font=f2, fill=CREAM, stroke_width=3, stroke_fill=PLUM)
    centered(d, W / 2, fy + 74, GITHUB, font("Medium", 26), CREAM)
    centered(d, W / 2, fy + 122, NOTICE, font("Medium", 18), (0xD8, 0xCB, 0xE6))
    y += FH
    return page.crop((0, 0, W, y)).convert("RGB")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(PROMO, "overlock_onepager.png"))
    a = ap.parse_args()
    im = build()
    im.save(a.out, optimize=True)
    print("wrote", a.out, im.size)


if __name__ == "__main__":
    main()
