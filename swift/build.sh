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

# --- 4. Signature -----------------------------------------------------------
# Ad-hoc par défaut : simple, mais chaque reconstruction change l'identité, donc
# macOS redemande l'autorisation Accessibilité.
#
# Identité persistante (opt-in) : un certificat auto-signé créé une fois, et
# l'autorisation survit aux reconstructions suivantes.
#   AUTOCAP_PERSISTENT_IDENTITY=1 bash build.sh
IDENTITY_NAME="AutoCap Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

have_identity() { security find-certificate -c "$IDENTITY_NAME" "$KEYCHAIN" >/dev/null 2>&1; }

create_identity() {
    local tmpd
    tmpd="$(mktemp -d)" || return 1
    if ! openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -keyout "$tmpd/key.pem" -out "$tmpd/cert.pem" -subj "/CN=$IDENTITY_NAME" \
            -addext "basicConstraints=critical,CA:false" \
            -addext "keyUsage=critical,digitalSignature" \
            -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1; then
        echo "$LOG_PREFIX           génération du certificat impossible (openssl) -> ad-hoc"
        rm -rf "$tmpd"; return 1
    fi
    if ! openssl pkcs12 -export -out "$tmpd/id.p12" -inkey "$tmpd/key.pem" \
            -in "$tmpd/cert.pem" -name "$IDENTITY_NAME" -passout pass:autocap >/dev/null 2>&1; then
        echo "$LOG_PREFIX           conversion PKCS#12 impossible -> ad-hoc"
        rm -rf "$tmpd"; return 1
    fi
    security import "$tmpd/id.p12" -k "$KEYCHAIN" -P autocap -T /usr/bin/codesign -A >/dev/null 2>&1
    rm -rf "$tmpd"
    have_identity
}

SIGN_MODE=""
if [ "${AUTOCAP_PERSISTENT_IDENTITY:-0}" = "1" ]; then
    if have_identity || create_identity; then
        if codesign --force --sign "$IDENTITY_NAME" --timestamp=none "$APP" >/dev/null 2>&1; then
            SIGN_MODE="identité persistante ($IDENTITY_NAME)"
        fi
    fi
fi
if [ -z "$SIGN_MODE" ]; then
    if codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1; then
        SIGN_MODE="ad-hoc"
    else
        SIGN_MODE="échec de signature (l'application peut tout de même se lancer)"
    fi
fi
echo "$LOG_PREFIX signature : $SIGN_MODE"
if [ "$SIGN_MODE" = "ad-hoc" ]; then
    echo "$LOG_PREFIX           note : chaque reconstruction redemandera l'autorisation Accessibilité"
fi

# --- 5. Empreinte -----------------------------------------------------------
if command -v shasum >/dev/null 2>&1; then
    echo "$LOG_PREFIX empreinte : $(shasum -a 256 "$APP/Contents/MacOS/AutoCap" | cut -c1-16)"
fi

echo "$LOG_PREFIX VERDICT : AutoCap.app prêt dans $APP"
exit 0
