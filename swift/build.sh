#!/bin/bash
# ============================================================================
#  build.sh — construit AutoCap.app (Swift, aucun interpréteur, aucune dépendance)
#
#  Sortie : un bundle signé ad-hoc à l'emplacement demandé (défaut
#  ~/Applications/AutoCap.app). La signature ad-hoc donne au système une identité
#  stable : l'autorisation Accessibilité porte sur une APPLICATION, pas sur un
#  interpréteur dans un venv qui change à chaque mise à jour.
#
#  Lignes attendues :
#    [build] swiftc : <version>
#    [build] sources : N fichiers
#    [build] binaire : <chemin> (<taille>)
#    [build] signature : ok | avertissement
#    [build] VERDICT : AutoCap.app prêt
#  En cas d'échec, la sortie de swiftc est imprimée ENTIÈRE (jamais tronquée).
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${1:-$HOME/Applications/AutoCap.app}"
LOG_PREFIX="[build]"

fail() { echo "$LOG_PREFIX ERREUR : $*" >&2; exit 1; }

echo "$LOG_PREFIX démarré $(date '+%Y-%m-%d %H:%M:%S') sur $(uname -m) / macOS $(sw_vers -productVersion 2>/dev/null || echo '?')"

# --- 1. Chaîne de compilation -----------------------------------------------
SWIFTC="$(command -v swiftc || true)"
if [ -z "$SWIFTC" ] && command -v xcrun >/dev/null 2>&1; then
    SWIFTC="$(xcrun --find swiftc 2>/dev/null || true)"
fi
[ -n "$SWIFTC" ] || fail "swiftc introuvable. Installe les outils de développement :
    xcode-select --install
puis relance cette commande."
echo "$LOG_PREFIX swiftc : $("$SWIFTC" --version 2>&1 | head -2 | tr '\n' ' ')"

[ -d "$HERE/Sources" ] || fail "dossier Sources absent dans $HERE"
[ -f "$HERE/Resources/Info.plist" ] || fail "Resources/Info.plist absent dans $HERE"

SOURCES=()
while IFS= read -r line; do SOURCES+=("$line"); done < <(find "$HERE/Sources" -name '*.swift' | sort)
[ "${#SOURCES[@]}" -gt 0 ] || fail "aucun fichier .swift trouvé dans $HERE/Sources"
echo "$LOG_PREFIX sources : ${#SOURCES[@]} fichiers"

# --- 2. Bundle ---------------------------------------------------------------
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" || fail "impossible de créer $APP"
cp "$HERE/Resources/Info.plist" "$APP/Contents/Info.plist" || fail "copie Info.plist impossible"

# --- 3. Compilation ---------------------------------------------------------
echo "$LOG_PREFIX compilation…"
BUILD_OUT="$("$SWIFTC" -O -whole-module-optimization -swift-version 5 \
    -module-name AutoCap \
    -o "$APP/Contents/MacOS/AutoCap" \
    "${SOURCES[@]}" \
    -framework Cocoa -framework ApplicationServices -framework CoreGraphics 2>&1)"
BUILD_STATUS=$?
if [ $BUILD_STATUS -ne 0 ]; then
    echo "$BUILD_OUT" >&2
    fail "la compilation a échoué (code $BUILD_STATUS) — la sortie complète est ci-dessus.
Rien n'a été installé : l'ancienne version, si elle existe, est intacte."
fi
[ -n "$BUILD_OUT" ] && echo "$BUILD_OUT"
[ -x "$APP/Contents/MacOS/AutoCap" ] || fail "binaire absent après compilation"

SIZE="$(stat -f%z "$APP/Contents/MacOS/AutoCap" 2>/dev/null || echo '?')"
echo "$LOG_PREFIX binaire : $APP/Contents/MacOS/AutoCap ($SIZE octets)"

# --- 4. Signature ad-hoc ----------------------------------------------------
if codesign --force --sign - --timestamp=none "$APP" 2>/dev/null; then
    echo "$LOG_PREFIX signature : ok ($(codesign -dv "$APP" 2>&1 | grep -m1 'Signature' || echo 'ad-hoc'))"
else
    echo "$LOG_PREFIX signature : avertissement — signature ad-hoc impossible."
    echo "                 L'application fonctionnera, mais macOS redemandera"
    echo "                 l'autorisation Accessibilité après chaque reconstruction."
fi

# --- 5. Empreinte -----------------------------------------------------------
if command -v shasum >/dev/null 2>&1; then
    echo "$LOG_PREFIX empreinte : $(shasum -a 256 "$APP/Contents/MacOS/AutoCap" | cut -c1-16)"
fi

echo "$LOG_PREFIX VERDICT : AutoCap.app prêt dans $APP"
exit 0
