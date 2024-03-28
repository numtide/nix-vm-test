#! /usr/bin/env nix-shell
#! nix-shell -i python3 -p python3 python3Packages.beautifulsoup4 python3Packages.requests nix-prefetch

import re
import requests
import subprocess
import json
from bs4 import BeautifulSoup
from datetime import datetime


def nix_hash(url):
    print(f"[+] Calculating Nix hash for {url}")
    res = subprocess.run(["nix-prefetch-url", url], stdout=subprocess.PIPE)
    return res.stdout.rstrip().decode("utf-8")

def get_latest_debian_image(url):
    print(f"[+] Parsing debian index {url}")
    # Step 1: retrieve the latest entry
    page = requests.get(url)
    soup = BeautifulSoup(page.content, "html.parser")
    rows = soup.find_all("tr")
    l = [row.a["href"] for row in rows if row.a]
    # Filtering out non-datetime entries such as "daily" or "latest"
    l = [s for s in l if re.compile("^[0-9]{8}-[0-9]{4}/$").match(s)]
    # Parsing date part of the string
    parsed_l = [(datetime.strptime(s[:8], '%Y%m%d'), s) for s in l]
    latest = max(parsed_l)
    url = f"{url}/{latest[1]}"
    print(f"[+] Parsing latest entry: {url}")

    # Step 2: parse entry
    page = requests.get(url)
    soup = BeautifulSoup(page.content, "html.parser")
    rows = soup.find_all("tr")
    l = [row.a["href"] for row in rows if row.a]
    res = {}
    for s in l:
        if re.compile("^.*-generic-.*\.qcow2$").match(s):
            if "amd64" in s:
                res["x86_64-linux"] = f"{url}{s}"
            elif "arm64" in s:
                res["aarch64-linux"] = f"{url}{s}"
    return res

"""
Parse the debian cloudimages
"""
def debian_parse():
    bookworm_url = "https://cloud.debian.org/images/cloud/bookworm"
    trixie_url = "https://cloud.debian.org/images/cloud/trixie/daily"
    bookworm = get_latest_debian_image(bookworm_url)
    trixie = get_latest_debian_image(trixie_url)
    res = {}
    for arch in bookworm.keys():
        res[arch] = {
            "12": {
                "name": bookworm[arch],
                "hash": nix_hash(bookworm[arch])

            },
            "13": {
                "name": trixie[arch],
                "hash": nix_hash(trixie[arch])
            }
        }
    return json.dumps(res)

if __name__ == '__main__':
    debian_json = debian_parse()
    with open("debian.json", "w") as f:
        f.write(debian_json)
