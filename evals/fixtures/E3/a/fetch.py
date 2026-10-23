import json
import urllib.request


def fetch_rates(url):
    with urllib.request.urlopen(url, timeout=10) as resp:
        return json.load(resp)["rates"]
