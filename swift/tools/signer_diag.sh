#!/bin/bash
# ============================================================================
#  signer_diag.sh — pourquoi la signature persistante échoue-t-elle ?
#
#  Crée (si absente) l'identité de signature « AutoCap Local Signing » dans le
#  trousseau de session, en affichant CHAQUE étape et son erreur réelle.
#
#  But : qu'une autorisation Accessibilité accordée une fois survive à toutes les
#  reconstructions, au lieu d'être redemandée à chaque compilation (signature
#  ad-hoc = identité qui change à chaque binaire).
#
#  Ce que le script modifie : il ajoute un certificat auto-signé et sa clé privée
#  dans ~/Library/Keychains/login.keychain-db (une seule fois). Rien d'autre.
#
#  Lignes attendues en cas de succès :
#    [sign] VERDICT : identité persistante opérationnelle.
#  En cas d'échec : l'étape fautive, son code de sortie et la sortie d'erreur
#  complète de l'outil — jamais un « échec » nu.
# ============================================================================
set -uo pipefail

IDENTITY_NAME="AutoCap Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

say()  { echo "[sign] $*"; }
fail() { echo "[sign] ERREUR : $*" >&2
         echo "[sign] VERDICT : identité persistante indisponible — la reconstruction reste ad-hoc," >&2
         echo "[sign]            donc l'autorisation Accessibilité sera à redonner à chaque fois." >&2
         exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "ce script doit tourner sur macOS."
say "macOS $(sw_vers -productVersion 2>/dev/null) ($(uname -m))"
say "openssl : $(openssl version 2>&1 | head -1)"
[ -f "$KEYCHAIN" ] || fail "trousseau introuvable : $KEYCHAIN"
say "trousseau : présent"

if security find-certificate -c "$IDENTITY_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    say "identité déjà présente dans le trousseau"
else
    say "1/3 génération du certificat (config portable, sans -addext)"
    cat > "$TMPD/req.cnf" <<'CNF'
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
    if ! openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -keyout "$TMPD/key.pem" -out "$TMPD/cert.pem" \
            -config "$TMPD/req.cnf" 2>"$TMPD/e1"; then
        cat "$TMPD/e1" >&2
        fail "openssl req a échoué"
    fi
    say "    ok — certificat de $(grep -c '^[A-Za-z0-9+/=]' "$TMPD/cert.pem") lignes"

    say "2/3 conversion PKCS#12"
    if ! openssl pkcs12 -export -out "$TMPD/id.p12" -inkey "$TMPD/key.pem" \
            -in "$TMPD/cert.pem" -name "$IDENTITY_NAME" \
            -passout [KEY REDACTED] 2>"$TMPD/e2"; then
        cat "$TMPD/e2" >&2
        fail "openssl pkcs12 a échoué"
    fi
    say "    ok"

    say "3/3 import dans le trousseau (codesign autorisé)"
    security import "$TMPD/id.p12" -k "$KEYCHAIN" -P autocap \
        -T /usr/bin/codesign 2>"$TMPD/e3"
    status=$?
    if [ $status -ne 0 ]; then
        cat "$TMPD/e3" >&2
        fail "security import a échoué (code $status)"
    fi
    say "    ok"
fi

security find-certificate -c "$IDENTITY_NAME" "$KEYCHAIN" >/dev/null 2>&1 \
    || fail "le certificat n'est pas lisible dans le trousseau après import"
say "certificat lisible dans le trousseau"

say "test réel : signature d'un binaire jetable"
cp /bin/echo "$TMPD/probe" 2>/dev/null || fail "impossible de copier /bin/echo"
if ! codesign --force --sign "$IDENTITY_NAME" "$TMPD/probe" 2>"$TMPD/e4"; then
    cat "$TMPD/e4" >&2
    fail "codesign a refusé l'identité"
fi
say "    ok"
codesign -dv "$TMPD/probe" 2>&1 | head -5 | sed 's/^/[sign]     /'

echo ""
say "VERDICT : identité persistante opérationnelle."
say "Relance l'installeur : la ligne doit afficher « signature : identité persistante »."
say "À partir de là, une autorisation Accessibilité accordée une fois ne sera plus redemandée."
