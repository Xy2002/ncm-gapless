"""Keep the static Chinese landing page crawlable and its claims in sync."""
from html.parser import HTMLParser
import json
from pathlib import Path
import unittest
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / "site"


class Page(HTMLParser):
    def __init__(self, source):
        super().__init__()
        self.elements = []
        self.active = []
        self.feed(source)

    def handle_starttag(self, tag, attrs):
        element = {"tag": tag, "attrs": dict(attrs), "text": ""}
        self.elements.append(element)
        if tag in {"title", "h1", "script", "main"}:
            self.active.append(element)

    def handle_endtag(self, tag):
        self.active = [element for element in self.active if element["tag"] != tag]

    def handle_data(self, data):
        for element in self.active:
            element["text"] += data

    def find(self, tag, **attrs):
        return [element for element in self.elements
                if element["tag"] == tag
                and all(element["attrs"].get(key) == value for key, value in attrs.items())]


class SiteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (SITE / "index.html").read_text(encoding="utf-8")
        cls.page = Page(cls.source)
        cls.compatibility = json.loads((ROOT / "compatibility.json").read_text(encoding="utf-8"))

    def test_chinese_content_and_metadata(self):
        self.assertEqual(self.page.find("html")[0]["attrs"].get("lang"), "zh-CN")
        headings = self.page.find("h1")
        self.assertEqual(len(headings), 1)
        self.assertIn("网易云音乐无缝播放", "".join(headings[0]["text"].split()))
        self.assertTrue(self.page.find("title")[0]["text"].strip())
        self.assertTrue(self.page.find("meta", name="description")[0]["attrs"]["content"].strip())
        main = self.page.find("main")[0]["text"]
        for version in (self.compatibility["version"], self.compatibility["observed"]["clientVersion"],
                        self.compatibility["macos"]["observed"]["clientVersion"]):
            self.assertIn(version, main)
        for element in self.page.find("meta"):
            if element["attrs"].get("name", "").lower() in {"robots", "googlebot", "bingbot"}:
                self.assertNotIn("noindex", element["attrs"].get("content", "").lower())
        self.assertNotRegex(self.source, r"example\.(com|org|net)")

    def test_canonical_sitemap_and_software_data_agree(self):
        canonical = self.page.find("link", rel="canonical")
        self.assertEqual(len(canonical), 1)
        url = canonical[0]["attrs"]["href"]
        parsed = urlsplit(url)
        self.assertEqual(parsed.scheme, "https")
        self.assertTrue(parsed.netloc)
        self.assertFalse(parsed.query or parsed.fragment)
        self.assertEqual(self.page.find("meta", property="og:url")[0]["attrs"]["content"], url)
        sitemap = ET.parse(SITE / "sitemap.xml")
        self.assertEqual([loc.text for loc in sitemap.findall(".//{http://www.sitemaps.org/schemas/sitemap/0.9}loc")], [url])
        scripts = self.page.find("script")
        self.assertEqual(len(scripts), 1)
        self.assertEqual(scripts[0]["attrs"].get("type"), "application/ld+json")
        self.assertNotIn("src", scripts[0]["attrs"])
        app = json.loads(scripts[0]["text"])
        self.assertEqual(app["@context"], "https://schema.org")
        self.assertEqual(app["@type"], "SoftwareApplication")
        self.assertEqual(app["name"], "NCM Gapless")
        self.assertEqual(app["url"], url)
        self.assertEqual(app["description"], self.page.find("meta", name="description")[0]["attrs"]["content"])
        self.assertEqual(app["softwareVersion"], self.compatibility["version"])
        self.assertEqual(set(app["operatingSystem"]), {"Windows x64", "macOS Apple Silicon"})
        self.assertTrue({"offers", "aggregateRating", "review", "license"}.isdisjoint(app))

    def test_local_resources_and_anchor_links_resolve(self):
        ids = {element["attrs"]["id"] for element in self.page.elements if "id" in element["attrs"]}
        for element in self.page.elements:
            attrs = element["attrs"]
            self.assertFalse(any(name.startswith("on") for name in attrs), element)
            for key in ("href", "src"):
                if key not in attrs:
                    continue
                value = urlsplit(attrs[key])
                if value.scheme or value.netloc:
                    continue
                with self.subTest(url=attrs[key]):
                    path = (SITE / unquote(value.path)).resolve()
                    self.assertTrue(path.is_relative_to(SITE))
                    self.assertTrue(path.exists(), path)
                    if not value.path and value.fragment:
                        self.assertIn(unquote(value.fragment), ids)


if __name__ == "__main__":
    unittest.main()
