"""Draw a simple code-native download symbol without external dependencies."""
import json
import pathlib
import struct
import zlib

size = 1024
rows = bytearray()
for y in range(size):
    rows.append(0)
    for x in range(size):
        stem = 450 <= x < 574 and 220 <= y < 550
        arrow = 470 <= y < 700 and abs(x - 512) <= (700 - y)
        tray = (250 <= x < 774 and 740 <= y < 800) or ((250 <= x < 310 or 714 <= x < 774) and 660 <= y < 800)
        rows.extend((255, 255, 255) if stem or arrow or tray else (249, 115, 22))

def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))

png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')
root = pathlib.Path(__file__).resolve().parents[1]
(root / 'icon.png').write_bytes(png)
assets = root / 'App/Assets.xcassets/AppIcon.appiconset'
assets.mkdir(parents=True, exist_ok=True)
(assets / 'icon.png').write_bytes(png)
(assets / 'Contents.json').write_text(json.dumps({'images': [{'filename': 'icon.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}], 'info': {'author': 'xcode', 'version': 1}}))
