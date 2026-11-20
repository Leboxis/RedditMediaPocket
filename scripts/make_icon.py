"""Génère l'icône de l'app — variante B « Console d'archive » (validée).

Fond en dégradé vertical charbon #1A1A1E → #0B0B0C, flèche de téléchargement
orange #FF9F0A vers le bas, bac en U aux coins arrondis en brun orangé #8A5408.
Rendu 2048 puis rééchantillonné 1024 (filtre boîte) pour des bords nets.
Aucune dépendance externe.
"""
import json
import pathlib
import struct
import zlib

size = 1024
ss = 2  # supersampling
big = size * ss

BG_TOP = (0x1A, 0x1A, 0x1E)
BG_BOT = (0x0B, 0x0B, 0x0C)
ACCENT = (0xFF, 0x9F, 0x0A)   # flèche
TRAY = (0x8A, 0x54, 0x08)     # bac atténué


def lerp(c1, c2, t):
    return tuple(round(a + (b - a) * t) for a, b in zip(c1, c2))


def in_arrow(x, y):
    # Tige
    if 467 * ss <= x < 557 * ss and 170 * ss <= y < 560 * ss:
        return True
    # Tête triangulaire vers le bas : large en haut (y=540), pointe en bas (y=720)
    if 540 * ss <= y < 720 * ss:
        half = 165 * ss * (1 - (y - 540 * ss) / (180 * ss))
        return abs(x - 512 * ss) <= half
    return False


def rounded_rect(x, y, x0, y0, x1, y1, r):
    if not (x0 <= x < x1 and y0 <= y < y1):
        return False
    cx = min(max(x, x0 + r), x1 - r - 1)
    cy = min(max(y, y0 + r), y1 - r - 1)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def in_tray(x, y):
    # Bac en U : deux parois + fond, coins arrondis r=30 (échelle 1024)
    wall_l = rounded_rect(x, y, 290 * ss, 700 * ss, 350 * ss, 840 * ss, 30 * ss)
    wall_r = rounded_rect(x, y, 674 * ss, 700 * ss, 734 * ss, 840 * ss, 30 * ss)
    bottom = rounded_rect(x, y, 290 * ss, 780 * ss, 734 * ss, 840 * ss, 30 * ss)
    return wall_l or wall_r or bottom


def pixel(x, y):
    if in_arrow(x, y):
        return ACCENT
    if in_tray(x, y):
        return TRAY
    return lerp(BG_TOP, BG_BOT, y / big)


rows = bytearray()
for y in range(big):
    rows.append(0)
    for x in range(big):
        rows.extend(pixel(x, y))

# Rééchantillonnage boîte ss x ss -> 1024
stride = 1 + 3 * big
small = bytearray()
for y in range(size):
    small.append(0)
    for x in range(size):
        r = g = b = 0
        for dy in range(ss):
            base = (y * ss + dy) * stride + 1
            for dx in range(ss):
                i = base + (x * ss + dx) * 3
                r += rows[i]; g += rows[i + 1]; b += rows[i + 2]
        n = ss * ss
        small.extend((r // n, g // n, b // n))


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))


png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 2, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(bytes(small)))
       + chunk(b'IEND', b''))

root = pathlib.Path(__file__).resolve().parents[1]
(root / 'icon.png').write_bytes(png)
assets = root / 'App/Assets.xcassets/AppIcon.appiconset'
assets.mkdir(parents=True, exist_ok=True)
(assets / 'icon.png').write_bytes(png)
(assets / 'Contents.json').write_text(json.dumps({'images': [{'filename': 'icon.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}], 'info': {'author': 'xcode', 'version': 1}}))
