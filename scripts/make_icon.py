"""Génère l'icône de l'app (direction « Console d'archive »).

Fond sombre DS.background dark (#0B0B0C), glyphe « télécharger » en accent
#FF9F0A, bac en accent atténué — rendu 2048 puis rééchantillonné 1024
(filtre boîte) pour des bords nets. Aucune dépendance externe.
"""
import json
import pathlib
import struct
import zlib

size = 1024
ss = 2  # supersampling
big = size * ss

BG = (0x0B, 0x0B, 0x0C)       # DS.background (dark)
ACCENT = (0xFF, 0x9F, 0x0A)   # DS.accent (dark)
TRAY_ALPHA = 0.55             # bac = accent atténué sur le fond


def tray_color():
    return tuple(round(bg + (ac - bg) * TRAY_ALPHA) for bg, ac in zip(BG, ACCENT))


def in_shaft(x, y):
    return 467 * ss <= x < 557 * ss and 190 * ss <= y < 560 * ss


def in_head(x, y):
    # Triangle de la flèche vers le bas : large en haut (y=560), pointe en bas (y=730).
    if not (560 * ss <= y < 730 * ss):
        return False
    half = 165 * ss * (1 - (y - 560 * ss) / (170 * ss))
    return abs(x - 512 * ss) <= half


def in_tray(x, y):
    bar = 290 * ss <= x < 734 * ss and 780 * ss <= y < 835 * ss
    wall = (290 * ss <= x < 345 * ss or 679 * ss <= x < 734 * ss) and 700 * ss <= y < 835 * ss
    return bar or wall


def pixel(x, y):
    if in_shaft(x, y) or in_head(x, y):
        return ACCENT
    if in_tray(x, y):
        return tray_color()
    return BG


rows = bytearray()
for y in range(big):
    rows.append(0)
    for x in range(big):
        rows.extend(pixel(x, y))

# Rééchantillonnage boîte ss x ss -> 1024
stride = 1 + 3 * big  # octet filtre + big pixels RGB par ligne
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
