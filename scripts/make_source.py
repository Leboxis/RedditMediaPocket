"""Generate the LiveContainer source only after a real IPA has been built."""
import argparse
import datetime
import json
import pathlib
import re
import zipfile


def build_source(repo, version, ipa):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise ValueError("Invalid owner/repository")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Version must be major.minor.patch")
    ipa = pathlib.Path(ipa)
    with zipfile.ZipFile(ipa) as archive:
        if "Payload/RedditMediaPocket.app/Info.plist" not in archive.namelist():
            raise ValueError("IPA missing app Info.plist")
    base = f"https://github.com/{repo}/releases/download/v{version}"
    return {
        "name": "Reddit Media Pocket",
        "identifier": "com.leboxis.redditmediapocket.source",
        "subtitle": "Médias Reddit publics — prototype RSS",
        "website": f"https://github.com/{repo}",
        "iconURL": f"{base}/icon.png",
        "apps": [{
            "name": "Reddit Media Pocket",
            "bundleIdentifier": "com.leboxis.RedditMediaPocket",
            "developerName": repo.split('/')[0],
            "subtitle": "Télécharge les médias accessibles",
            "localizedDescription": "Prototype sans compte Reddit : images directes, vidéos Reddit et RedGIFs via RSS. Historique complet et galeries non garantis. Garder l’application ouverte.",
            "iconURL": f"{base}/icon.png",
            "tintColor": "F97316",
            "versions": [{
                "version": version,
                "date": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
                "localizedDescription": "Trois téléchargements simultanés, galerie avec miniatures et interface épurée.",
                "downloadURL": f"{base}/{ipa.name}",
                "size": ipa.stat().st_size,
                "minOSVersion": "16.0"
            }]
        }],
        "news": []
    }


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--repo", required=True)
    p.add_argument("--version", required=True)
    p.add_argument("--ipa", required=True)
    p.add_argument("--output", required=True)
    a = p.parse_args()
    pathlib.Path(a.output).write_text(json.dumps(build_source(a.repo, a.version, a.ipa), ensure_ascii=False, indent=2) + "\n")
