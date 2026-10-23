#!/bin/bash
# ============================================================================
#  build.sh — construit AutoCap.app (Swift, aucun interpréteur, aucune dépendance)
#
#  Sortie : un bundle signé, à l'emplacement demandé (défaut ~/Applications/AutoCap.app).
#
#  Signature : une identité PERSISTANTE (« AutoCap Local Signing ») créée une
#  fois dans le trousseau, pour que l'autorisation Accessibilité survive aux
#  reconstructions. Une signature ad-hoc change d'identité à chaque binaire, donc
#  macOS redemande l'autorisation à chaque fois : c'est précisément ce qu'on
#  supprime ici. Repli honnête sur l'ad-hoc si le certificat ne peut être créé.
#
#  Aucun mot de passe, aucun PKCS#12 : clé privée et certificat sont importés
#  directement au format PEM.
#
#  Lignes attendues :
#    [build] swiftc : <version>
#    [build] sources : N fichiers
#    [build] binaire : <chemin> (<taille>)
#    [build] signature : identité persistante (AutoCap Local Signing) | ad-hoc
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
IDENTITY_NAME="AutoCap Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

have_identity() { security find-certificate -c "$IDENTITY_NAME" "$KEYCHAIN" >/dev/null 2>&1; }

create_identity() {
    local tmpd
    tmpd="$(mktemp -d)" || return 1
    cat > "$tmpd/req.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = AutoCap Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
    # Portable on both OpenSSL and LibreSSL: the extensions live in a config file
    # rather than on the command line.
    if ! openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -keyout "$tmpd/key.pem" -out "$tmpd/cert.pem" \
            -config "$tmpd/req.cnf" 2>"$tmpd/e1"; then
        echo "$LOG_PREFIX           certificat : ÉCHEC — $(head -3 "$tmpd/e1" | tr '\n' ' ')"
        echo "$LOG_PREFIX           diagnostic complet : bash tools/signer_diag.sh"
        rm -rf "$tmpd"; return 1
    fi
    # Direct PEM imports: no password to transmit, so no argument can be mangled.
    if ! security import "$tmpd/key.pem" -k "$KEYCHAIN" -T /usr/bin/codesign \
            >/dev/null 2>"$tmpd/e2"; then
        echo "$LOG_PREFIX           clé privée : ÉCHEC — $(head -3 "$tmpd/e2" | tr '\n' ' ')"
        rm -rf "$tmpd"; return 1
    fi
    if ! security import "$tmpd/cert.pem" -k "$KEYCHAIN" -T /usr/bin/codesign \
            >/dev/null 2>"$tmpd/e3"; then
        echo "$LOG_PREFIX           certificat : ÉCHEC — $(head -3 "$tmpd/e3" | tr '\n' ' ')"
        rm -rf "$tmpd"; return 1
    fi
    rm -rf "$tmpd"
    have_identity
}

SIGN_MODE=""
if [ "${AUTOCAP_PERSISTENT_IDENTITY:-1}" = "1" ]; then
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
    echo "$LOG_PREFIX           note : signature ad-hoc, donc chaque reconstruction redemandera"
    echo "$LOG_PREFIX                  l'autorisation Accessibilité. Diagnostic : bash tools/signer_diag.sh"
    echo "$LOG_PREFIX                  forcer l'ad-hoc : AUTOCAP_PERSISTENT_IDENTITY=0 bash build.sh"
fi

# --- 5. Empreinte -----------------------------------------------------------
if command -v shasum >/dev/null 2>&1; then
    echo "$LOG_PREFIX empreinte : $(shasum -a 256 "$APP/Contents/MacOS/AutoCap" | cut -c1-16)"
fi

echo "$LOG_PREFIX VERDICT : AutoCap.app prêt dans $APP"
exit 0
