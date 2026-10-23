#!/usr/bin/env python3
"""Verify the public delivery: raw content hash, size, and anonymous API state."""
import hashlib
import json
import urllib.request
import urllib.error
import time
from pathlib import Path

LOCAL = Path('/workspace/autocap-swift/install.sh').read_bytes()
TARGET = 'https://raw.githubusercontent.com/Spymack/autocapitalize/main/swift/install.sh'

for attempt in range(1, 7):
    try:
        with urllib.request.urlopen(TARGET, timeout=30) as response:
            remote = response.read()
            same = hashlib.sha256(remote).hexdigest() == hashlib.sha256(LOCAL).hexdigest()
            print(f'tentative {attempt}: HTTP {response.status} '
                  f'{len(remote)} octets | identique au local : {same}')
            if same:
                break
    except urllib.error.HTTPError as error:
        print(f'tentative {attempt}: HTTP {error.code}')
    time.sleep(5)

try:
    with urllib.request.urlopen(urllib.request.Request(
            'https://api.github.com/repos/Spymack/autocapitalize',
            headers={'User-Agent': 'x'}), timeout=30) as response:
        data = json.loads(response.read())
        print('API anonyme: HTTP', response.status, '| private =', data.get('private'))
except urllib.error.HTTPError as error:
    print('API anonyme: HTTP', error.code, '(le CDN garde parfois la réponse 60 s)')
