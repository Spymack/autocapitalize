#!/usr/bin/env python3
"""Diagnose the delivery channel: repo visibility, token validity, raw CDN state."""
import json
import re
import urllib.request
import urllib.error
from pathlib import Path

ENV = Path('/home/hermes/.hermes/.env')
TOKEN = None
for line in ENV.read_text().splitlines():
    if line.strip().startswith('GITHUB_PERSONAL_ACCESS_TOKEN='):
        TOKEN = re.sub(r'["\'\s]', '', line.split('=', 1)[1])

AUTH = {'Authorization': 'Bearer ' + TOKEN, 'Accept': 'application/vnd.github+json',
        'User-Agent': 'autocap-diagnose'}


def probe(label, url, headers=None):
    request = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read()
            print(f'{label}: HTTP {response.status} ({len(body)} octets)')
            return response.status, body
    except urllib.error.HTTPError as error:
        body = error.read()
        print(f'{label}: HTTP {error.code} ({len(body)} octets) {body[:120]!r}')
        return error.code, body
    except Exception as error:
        print(f'{label}: ECHEC {error}')
        return None, b''


print('token:', len(TOKEN) if TOKEN else None, 'caractères')
status, body = probe('  /user (authentifié)', 'https://api.github.com/user', AUTH)
if status == 200:
    print('  login:', json.loads(body).get('login'))

status, body = probe('  /repos (authentifié)', 'https://api.github.com/repos/Spymack/autocapitalize', AUTH)
if status == 200:
    data = json.loads(body)
    print('  private:', data.get('private'), '| visibility:', data.get('visibility'),
          '| pushed:', data.get('pushed_at'))

probe('  /repos (anonyme)', 'https://api.github.com/repos/Spymack/autocapitalize')

probe('  raw install.sh', 'https://raw.githubusercontent.com/Spymack/autocapitalize/main/swift/install.sh',
      {'User-Agent': 'curl/8'})
probe('  raw README racine', 'https://raw.githubusercontent.com/Spymack/autocapitalize/main/README.md',
      {'User-Agent': 'curl/8'})
probe('  jsdelivr install.sh', 'https://cdn.jsdelivr.net/gh/Spymack/autocapitalize@main/swift/install.sh',
      {'User-Agent': 'curl/8'})
