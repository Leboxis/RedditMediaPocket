import pathlib
import tempfile
import unittest
import zipfile
from make_source import build_source


class SourceTests(unittest.TestCase):
    def test_real_size_and_versioned_url(self):
        with tempfile.TemporaryDirectory() as d:
            ipa = pathlib.Path(d) / "RedditMediaPocket.ipa"
            with zipfile.ZipFile(ipa, "w") as z:
                z.writestr("Payload/RedditMediaPocket.app/Info.plist", "fixture")
            source = build_source("Leboxis/RedditMediaPocket", "0.1.3", ipa)
            version = source["apps"][0]["versions"][0]
            self.assertEqual(version["size"], ipa.stat().st_size)
            self.assertEqual(version["downloadURL"], "https://github.com/Leboxis/RedditMediaPocket/releases/download/v0.1.3/RedditMediaPocket.ipa")
            self.assertEqual(source["apps"][0]["bundleIdentifier"], "com.leboxis.RedditMediaPocket")

    def test_invalid_inputs(self):
        for repo, version in [("bad", "0.1.0"), ("a/b", "v0.1.0")]:
            with self.assertRaises(ValueError):
                build_source(repo, version, "absent.ipa")

    def test_invalid_archive(self):
        with tempfile.TemporaryDirectory() as d:
            ipa = pathlib.Path(d) / "invalid.ipa"
            with zipfile.ZipFile(ipa, "w") as z:
                z.writestr("wrong.txt", "")
            with self.assertRaises(ValueError):
                build_source("a/b", "0.1.0", ipa)


if __name__ == "__main__":
    unittest.main()
