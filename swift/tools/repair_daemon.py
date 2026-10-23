#!/usr/bin/env python3
"""Repair Daemon.swift: drop the half-written quarantine block and its state.

The quarantine was an optimisation (ignore an app's text when it does not follow
typing). It is not needed for the fixes that matter, and the write filter mangled
its insertion — so it goes, cleanly, rather than shipping code nobody can trust.
"""
from pathlib import Path

path = Path('/workspace/autocap-swift/Sources/Mac/Daemon.swift')
text = path.read_text(encoding='utf-8')
before = len(text)

# 1. Remove the property block (from its doc comment to the duration constant).
start_marker = "    /// Per-application confidence in what AX publishes"
end_marker = "    private let quarantineDuration: TimeInterval = 60\n"
if start_marker in text:
    start = text.index(start_marker)
    end = text.index(end_marker) + len(end_marker)
    text = text[:start] + text[end:]
    print('propriétés de quarantaine retirées')

# 2. Remove the broken lookup block inside applyRead.
lines = text.split('\n')
out = []
skipping = False
removed = 0
for line in lines:
    stripped = line.strip()
    if stripped.startswith('// A quarantined application') :
        skipping = True
        continue
    if skipping:
        # skip until the closing brace of the if-block, then one blank line
        if stripped == '}':
            skipping = False
            removed += 1
            continue
        removed += 1
        continue
    # drop any leftover line the filter mangled
    if 'appKey' in line or ('quarantine' in line.lower() and 'text' not in line.lower()):
        removed += 1
        continue
    out.append(line)

text = '\n'.join(out)
path.write_text(text, encoding='utf-8')
print('lignes retirées :', removed)
print('taille :', before, '->', len(text))
