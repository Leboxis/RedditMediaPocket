"""Synchronise l'icône de l'app depuis `icon.png` vers le catalogue Xcode.

`icon.png` à la racine du dépôt est la source de vérité (PNG 1024×1024 opaque).
Ce script vérifie l'en-tête PNG, copie le fichier dans `AppIcon.appiconset` et
maintient son `Contents.json`, sans dépendance externe.
"""
import json
import pathlib
import struct

PNG_SIGNATURE = b'\x89PNG\r\n\x1a\n'


def verify_app_icon_png(data: bytes) -> None:
    if len(data) < 24 or data[:8] != PNG_SIGNATURE or data[12:16] != b'IHDR':
        raise ValueError('icon.png must be a valid PNG file')
    width, height = struct.unpack('>II', data[16:24])
    if (width, height) != (1024, 1024):
        raise ValueError(f'icon.png must be 1024x1024, got {width}x{height}')


def main() -> None:
    root = pathlib.Path(__file__).resolve().parents[1]
    source = root / 'icon.png'
    png = source.read_bytes()
    verify_app_icon_png(png)
    assets = root / 'App/Assets.xcassets/AppIcon.appiconset'
    assets.mkdir(parents=True, exist_ok=True)
    (assets / 'icon.png').write_bytes(png)
    (assets / 'Contents.json').write_text(json.dumps({
        'images': [{
            'filename': 'icon.png',
            'idiom': 'universal',
            'platform': 'ios',
            'size': '1024x1024',
        }],
        'info': {'author': 'xcode', 'version': 1},
    }))


if __name__ == '__main__':
    main()
