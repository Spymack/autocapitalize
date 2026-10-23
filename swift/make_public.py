#!/usr/bin/env python3
"""Try to make the repository public again, and report exactly what GitHub says."""
import json
import urllib.request
import urllib.error
from pathlib import Path

KEY = 'GITHUB_PERSONAL_ACCESS_TOKEN='
VALUE = None
for line in Path('/home/hermes/.hermes/.env').read_text().splitlines():
    if line.strip().startswith(KEY):
        VALUE = line.strip().split('=', 1)[1]
VALUE = ''.join(ch for ch in (VALUE or '') if ch not in '"\' \t\r\n')
print('valeur lue :', len(VALUE), 'caractères, préfixe', VALUE[:4])

URL = 'https://api.github.com/repos/Spymack/autocapitalize'
HEADERS = {'Authorization': 'Bearer ' + VALUE, 'Accept': 'application/vnd.github+json',
           'User-Agent': 'autocap-visibility'}

payload = json.dumps({'private': False, 'visibility': 'public'}).encode()
request = urllib.request.Request(URL, data=payload, headers=HEADERS, method='PATCH')
try:
    with urllib.request.urlopen(request, timeout=30) as response:
        data = json.loads(response.read())
        print('PATCH OK ->', response.status, '| private:', data.get('private'),
              '| visibility:', data.get('visibility'))
except urllib.error.HTTPError as error:
    print('PATCH REFUSÉ ->', error.code, error.read().decode()[:400])

for label, headers in (('authentifié', HEADERS), ('anonyme', {'User-Agent': 'x'})):
    try:
        with urllib.request.urlopen(urllib.request.Request(URL, headers=headers), timeout=30) as r:
            d = json.loads(r.read())
            print(f'{label}: HTTP {r.status} private={d.get("private")}')
    except urllib.error.HTTPError as e:
        print(f'{label}: HTTP {e.code} {e.read().decode()[:120]}')

try:
    with urllib.request.urlopen('https://raw.githubusercontent.com/Spymack/autocapitalize/main/swift/install.sh',
                                timeout=30) as r:
        print('raw install.sh: HTTP', r.status, len(r.read()), 'octets')
except urllib.error.HTTPError as e:
    print('raw install.sh: HTTP', e.code)
