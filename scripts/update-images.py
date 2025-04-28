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

    # Step 2: retrieve images
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

def get_latest_ubuntu_image(url):
    print(f"[+] Parsing ubuntu index {url}")
    # Step 1: retrieve the latest entry
    page = requests.get(url)
    soup = BeautifulSoup(page.content, "html.parser")
    links = soup.find_all("a")
    l = [link["href"] for link in links if re.compile("^release-.*[0-9]{8}/").match(link["href"])]
    parsed_l = [(datetime.strptime(s[8:-1], "%Y%m%d"), s) for s in l]
    latest = max(parsed_l)

    # Step 2: retrieve images
    url = f"{url}{latest[1]}"
    print(f"[+] Parsing latest entry: {url}")
    page = requests.get(url)
    soup = BeautifulSoup(page.content, "html.parser")
    links = soup.find_all("a")
    res = {}
    for link in links:
        if re.compile(".*-server-cloudimg.*\.img$").match(link["href"]):
            link = link["href"]
            if "amd64" in link:
                res["x86_64-linux"] = f"{url}{link}"
            elif "arm64" in link:
                res["aarch64-linux"] = f"{url}{link}"
    return res

def ubuntu_parse():
    oracular_url = "https://cloud-images.ubuntu.com/releases/oracular/"
    noble_url = "https://cloud-images.ubuntu.com/releases/noble/"
    mantic_url = "https://cloud-images.ubuntu.com/releases/23.10/"
    lunar_url = "https://cloud-images.ubuntu.com/releases/23.04/"
    kinetic_url = "https://cloud-images.ubuntu.com/releases/22.10/"
    jammy_url = "https://cloud-images.ubuntu.com/releases/22.04/"
    focal_url = "https://cloud-images.ubuntu.com/releases/focal/"
    oracular = get_latest_ubuntu_image(oracular_url)
    noble = get_latest_ubuntu_image(noble_url)
    mantic = get_latest_ubuntu_image(mantic_url)
    lunar = get_latest_ubuntu_image(lunar_url)
    kinetic = get_latest_ubuntu_image(kinetic_url)
    jammy = get_latest_ubuntu_image(jammy_url)
    focal = get_latest_ubuntu_image(focal_url)

    res = {}
    def gen_entry_dict(entry):
        return { "name": entry, "hash": nix_hash(entry) }
    for arch in mantic.keys():
        res[arch] = {
            "20_04": gen_entry_dict(focal[arch]),
            "22_04": gen_entry_dict(jammy[arch]),
            "22_10": gen_entry_dict(kinetic[arch]),
            "23_04": gen_entry_dict(lunar[arch]),
            "23_10": gen_entry_dict(mantic[arch]),
            "24_04": gen_entry_dict(noble[arch]),
            "24_10": gen_entry_dict(oracular[arch]),
        }
    return json.dumps(res)

if __name__ == '__main__':
    ubuntu_json = ubuntu_parse()
    with open("ubuntu.json", "w") as f:
        f.write(ubuntu_json)
    debian_json = debian_parse()
    with open("debian.json", "w") as f:
        f.write(debian_json)
