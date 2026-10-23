#!/usr/bin/env python3
"""Generate the self-contained installer (install.sh) from the sources.

Why embedded sources: codeload.github.com returned 404 on the user's network
while raw.githubusercontent.com worked. A single file that carries its own
sources removes that dependency entirely — one download, then nothing.

Each embedded file is written through a quoted heredoc, so no shell expansion
can touch a single byte of Swift source.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / 'tools' / 'install.template.sh'
TARGET = ROOT / 'install.sh'

# Order matters only for readability: the shell writes them one by one.
FILES = [
    'Sources/main.swift',
    'Sources/Core/Rules.swift',
    'Sources/Core/Align.swift',
    'Sources/Core/SelfTest.swift',
    'Sources/Mac/AX.swift',
    'Sources/Mac/Tap.swift',
    'Sources/Mac/Daemon.swift',
    'Sources/Mac/Log.swift',
    'Sources/Mac/Doctor.swift',
    'Sources/Mac/Install.swift',
    'Resources/Info.plist',
    'build.sh',
    'README.md',
]


def version() -> str:
    text = (ROOT / 'Sources/Mac/Daemon.swift').read_text(encoding='utf-8')
    match = re.search(r'static let version\s*=\s*"([^"]+)"', text)
    if not match:
        sys.exit('version introuvable dans Daemon.swift')
    return match.group(1)


def embed() -> str:
    blocks = []
    for index, relative in enumerate(FILES):
        path = ROOT / relative
        if not path.is_file():
            sys.exit(f'fichier manquant : {relative}')
        content = path.read_text(encoding='utf-8')
        if not content.endswith('\n'):
            content += '\n'
        delimiter = f'AUTOCAP_EOF_{index}'
        if delimiter in content:
            sys.exit(f'collision de délimiteur dans {relative}')
        parent = str(Path(relative).parent)
        if parent not in ('.', ''):
            blocks.append(f'mkdir -p "$SCRIPTS_DIR/{parent}" || fail "impossible de créer $SCRIPTS_DIR/{parent}"')
        blocks.append(f'cat > "$SCRIPTS_DIR/{relative}" <<\'{delimiter}\'\n{content}{delimiter}')
    return '\n'.join(blocks) + '\n'


def main() -> None:
    template = TEMPLATE.read_text(encoding='utf-8')
    for marker in ('@EMBED_SOURCES@', '@VERSION@'):
        if marker not in template:
            sys.exit(f'marqueur absent du gabarit : {marker}')
    output = template.replace('@VERSION@', version()).replace('@EMBED_SOURCES@', embed())
    TARGET.write_text(output, encoding='utf-8')
    TARGET.chmod(0o755)
    print(f'install.sh généré : {TARGET} ({len(output)} octets, {output.count(chr(10))} lignes)')
    print(f'version embarquée : {version()}')
    print(f'fichiers embarqués : {len(FILES)}')


if __name__ == '__main__':
    main()
