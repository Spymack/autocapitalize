#!/bin/bash
# ============================================================================
#  install.sh — AutoCap en UNE commande, sur le Mac.
#
#  Ce que fait ce script, dans l'ordre :
#    1. vérifie macOS et les outils de développement ;
#    2. récupère les sources (ou utilise celles qui sont à côté de lui) ;
#    3. les installe dans ~/Scripts/autocap-swift (convention : tout script vit là) ;
#    4. compile ~/Applications/AutoCap.app (Swift, binaire unique, signé ad-hoc) ;
#    5. lance la suite de conformité — et REFUSE d'installer si un cas échoue ;
#    6. désactive l'ancien démon Python (deux moteurs = majuscules en double) ;
#    7. installe et démarre l'agent launchd com.aurel.autocap ;
#    8. lance le diagnostic et affiche le VERDICT ;
#    9. affiche ce qui reste à faire à la main (l'autorisation macOS).
#
#  Lignes attendues :
#    [install] étape 1/9 …
#    [install] VERDICT : PRÊT … | [install] VERDICT : ACTION REQUISE …
#  Toute erreur est imprimée avec sa raison exacte ; rien n'est tronqué.
# ============================================================================
set -uo pipefail

REPO_TARBALL="https://codeload.github.com/Spymack/autocapitalize/tar.gz/refs/heads/main"
SCRIPTS_DIR="$HOME/Scripts/autocap-swift"
APP="$HOME/Applications/AutoCap.app"
BIN="$APP/Contents/MacOS/AutoCap"
LEGACY_LABEL="com.local.autocap"
LABEL="com.aurel.autocap"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say()  { echo "[install] $*"; }
fail() { echo "[install] ERREUR : $*" >&2; echo "[install] VERDICT : ÉCHEC — rien de cassé, l'installation précédente (si elle existe) est intacte." >&2; exit 1; }

say "démarrage $(date '+%Y-%m-%d %H:%M:%S') sur $(uname -m)"

# --- 1. Prérequis -----------------------------------------------------------
say "étape 1/9 — prérequis"
command -v sw_vers >/dev/null 2>&1 || fail "ce script doit tourner sur macOS."
OS_VERSION="$(sw_vers -productVersion)"
say "        macOS $OS_VERSION ($(uname -m))"

SWIFTC="$(command -v swiftc || true)"
if [ -z "$SWIFTC" ] && command -v xcrun >/dev/null 2>&1; then
    SWIFTC="$(xcrun --find swiftc 2>/dev/null || true)"
fi
if [ -z "$SWIFTC" ]; then
    fail "le compilateur Swift est absent. Installe les outils de développement :
    xcode-select --install
puis relance cette même commande."
fi
say "        swiftc : $("$SWIFTC" --version 2>&1 | head -1)"

# --- 2. Sources -------------------------------------------------------------
say "étape 2/9 — sources"
if [ -d "$HERE/Sources" ]; then
    SRC="$HERE"
    say "        sources locales : $SRC"
else
    say "        téléchargement des sources…"
    curl -fsSL "$REPO_TARBALL" -o "$TMP/repo.tgz" || fail "téléchargement impossible ($REPO_TARBALL)."
    tar -xzf "$TMP/repo.tgz" -C "$TMP" || fail "archive illisible."
    FOUND="$(find "$TMP" -maxdepth 3 -type d -name Sources | head -1)"
    [ -n "$FOUND" ] || fail "les sources ne contiennent pas de dossier Sources."
    SRC="$(dirname "$FOUND")"
    say "        sources extraites : $SRC"
fi

# --- 3. Installation des sources -------------------------------------------
say "étape 3/9 — sources dans ~/Scripts"
mkdir -p "$HOME/Scripts" || fail "impossible de créer ~/Scripts."
rm -rf "$SCRIPTS_DIR"
mkdir -p "$SCRIPTS_DIR"
cp -R "$SRC/." "$SCRIPTS_DIR/" || fail "copie des sources impossible."
say "        $SCRIPTS_DIR ($(find "$SCRIPTS_DIR/Sources" -name '*.swift' | wc -l | tr -d ' ') fichiers Swift)"

# --- 4. Compilation ---------------------------------------------------------
say "étape 4/9 — compilation"
mkdir -p "$HOME/Applications" || fail "impossible de créer ~/Applications."
bash "$SCRIPTS_DIR/build.sh" "$APP" || fail "la compilation a échoué (sortie complète ci-dessus)."
[ -x "$BIN" ] || fail "binaire absent après compilation : $BIN"

# --- 5. Conformité ----------------------------------------------------------
say "étape 5/9 — suite de conformité"
SELFTEST_OUT="$("$BIN" --selftest 2>&1)"
SELFTEST_STATUS=$?
echo "$SELFTEST_OUT"
[ $SELFTEST_STATUS -eq 0 ] || fail "la suite de conformité a échoué : l'installation est refusée."
echo "$SELFTEST_OUT" | grep -q "VERDICT: rules, trust and caret measurement agree" \
    || fail "verdict de conformité inattendu."

# --- 6. Ancien démon Python -------------------------------------------------
say "étape 6/9 — ancien démon Python"
launchctl bootout "gui/$(id -u)/$LEGACY_LABEL" 2>/dev/null && say "        $LEGACY_LABEL arrêté" || say "        $LEGACY_LABEL absent (rien à arrêter)"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
if [ -f "$LEGACY_PLIST" ]; then
    mv "$LEGACY_PLIST" "$LEGACY_PLIST.disabled" && say "        plist désactivé : $LEGACY_PLIST.disabled"
fi
pkill -f "autocapitalize.py" 2>/dev/null && say "        processus autocapitalize.py arrêté" || true

# --- 7. Agent launchd -------------------------------------------------------
say "étape 7/9 — agent launchd"
"$BIN" --install || fail "installation de l'agent impossible."

# --- 8. Diagnostic ----------------------------------------------------------
say "étape 8/9 — diagnostic"
DOCTOR_OUT="$("$BIN" --doctor 2>&1)"
DOCTOR_STATUS=$?
echo "$DOCTOR_OUT"

# --- 9. Vérification réelle -------------------------------------------------
say "étape 9/9 — vérification"
sleep 2
launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 \
    && say "        agent chargé (launchctl print OK)" \
    || say "        agent NON chargé — voir --status"
if pgrep -f "AutoCap.app/Contents/MacOS/AutoCap" >/dev/null 2>&1; then
    say "        processus en cours (pid $(pgrep -f 'AutoCap.app/Contents/MacOS/AutoCap' | head -1))"
else
    say "        processus non détecté pour l'instant (il attend peut-être l'autorisation)"
fi
say "        dernières lignes du journal :"
tail -6 "$HOME/Library/Logs/autocap.log" 2>/dev/null | sed 's/^/[install]           /' || say "        (journal pas encore créé)"

echo ""
if [ $DOCTOR_STATUS -eq 0 ]; then
    echo "[install] VERDICT : PRÊT — AutoCap tourne."
else
    cat <<EOF
[install] VERDICT : ACTION REQUISE (1 geste, une seule fois)

  1. Réglages Système > Confidentialité et sécurité > Accessibilité
     cliquer « + », puis ⌘⇧G et coller :

$APP

     Activer l'interrupteur d'AutoCap.

  2. Si le journal parle de « Input Monitoring », faire de même dans
     Confidentialité et sécurité > Surveillance de l'entrée.

  3. Puis relancer l'agent (une ligne) :

launchctl kickstart -k gui/$(id -u)/$LABEL

  4. Vérifier (une ligne) :

"$BIN" --doctor
EOF
fi

echo ""
echo "[install] commandes utiles :"
echo "    \"$BIN\" --status"
echo "    \"$BIN\" --doctor"
echo "    tail -f \"$HOME/Library/Logs/autocap.log\""
echo "    \"$BIN\" --uninstall"
