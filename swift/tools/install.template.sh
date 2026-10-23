#!/bin/bash
# ============================================================================
#  AutoCap — installeur AUTONOME (une seule commande, aucun téléchargement).
#
#  Ce fichier contient TOUTES les sources de l'application. Il les écrit dans
#  ~/Scripts/autocap-swift, compile ~/Applications/AutoCap.app, exécute la suite
#  de conformité, refuse d'installer si un cas échoue, désactive l'ancien démon
#  Python, installe l'agent launchd, puis affiche un verdict.
#
#  Aucune requête réseau après le téléchargement de ce fichier : la panne
#  « codeload 404 » ne peut plus se produire.
#
#  Lignes attendues :
#    [install] étape N/9 — …
#    [install] VERDICT : PRÊT — AutoCap tourne.
#    [install] VERDICT : ACTION REQUISE (1 geste, une seule fois)
#    [install] VERDICT : ÉCHEC — rien de cassé, l'installation précédente intacte.
#  Toute erreur affiche sa raison exacte ; aucune sortie n'est tronquée.
#
#  Généré par tools/make_install.py — ne pas éditer à la main.
#  Version embarquée : @VERSION@
# ============================================================================
set -uo pipefail

SCRIPTS_DIR="$HOME/Scripts/autocap-swift"
APP="$HOME/Applications/AutoCap.app"
BIN="$APP/Contents/MacOS/AutoCap"
LEGACY_LABEL="com.local.autocap"
LABEL="com.aurel.autocap"

say()  { echo "[install] $*"; }
fail() { echo "[install] ERREUR : $*" >&2; echo "[install] VERDICT : ÉCHEC — rien de cassé, l'installation précédente (si elle existe) est intacte." >&2; exit 1; }

say "démarrage $(date '+%Y-%m-%d %H:%M:%S') — AutoCap @VERSION@"

# --- 1. Prérequis -----------------------------------------------------------
say "étape 1/9 — prérequis"
command -v sw_vers >/dev/null 2>&1 || fail "ce script doit tourner sur macOS."
[ "$(uname -s)" = "Darwin" ] || fail "système détecté : $(uname -s) — ce script exige macOS."
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

# --- 2. Sources embarquées --------------------------------------------------
say "étape 2/9 — écriture des sources embarquées"
[ -n "${HOME:-}" ] || fail "HOME n'est pas défini."
mkdir -p "$SCRIPTS_DIR" || fail "impossible de créer $SCRIPTS_DIR"
@EMBED_SOURCES@

# --- 3. Vérification des sources -------------------------------------------
say "étape 3/9 — contrôle des sources"
SWIFT_COUNT=$(find "$SCRIPTS_DIR/Sources" -name '*.swift' | wc -l | tr -d ' ')
[ "$SWIFT_COUNT" -ge 11 ] || fail "sources incomplètes : $SWIFT_COUNT fichier(s) Swift au lieu de 11."
[ -f "$SCRIPTS_DIR/Resources/Info.plist" ] || fail "Resources/Info.plist manquant."
[ -f "$SCRIPTS_DIR/build.sh" ] || fail "build.sh manquant."
chmod +x "$SCRIPTS_DIR/build.sh"
say "        $SWIFT_COUNT fichiers Swift + Info.plist + build.sh"

# --- 4. Compilation ---------------------------------------------------------
say "étape 4/9 — compilation"
mkdir -p "$HOME/Applications" || fail "impossible de créer ~/Applications."
bash "$SCRIPTS_DIR/build.sh" "$APP" || fail "la compilation a échoué (sortie complète ci-dessus). Rien n'a été installé."
[ -x "$BIN" ] || fail "binaire absent après compilation : $BIN"

# --- 5. Conformité ----------------------------------------------------------
say "étape 5/9 — suite de conformité"
SELFTEST_OUT="$("$BIN" --selftest 2>&1)"
SELFTEST_STATUS=$?
echo "$SELFTEST_OUT"
[ $SELFTEST_STATUS -eq 0 ] || fail "la suite de conformité a échoué : installation refusée."
echo "$SELFTEST_OUT" | grep -q "agree with the contract" || fail "verdict de conformité inattendu."

# --- 6. Ancien démon Python -------------------------------------------------
say "étape 6/9 — ancien démon Python"
if launchctl bootout "gui/$(id -u)/$LEGACY_LABEL" 2>/dev/null; then
    say "        $LEGACY_LABEL arrêté"
else
    say "        $LEGACY_LABEL absent (rien à arrêter)"
fi
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
if [ -f "$LEGACY_PLIST" ]; then
    mv "$LEGACY_PLIST" "$LEGACY_PLIST.disabled" && say "        plist désactivé : $LEGACY_PLIST.disabled"
fi
if pkill -f "autocapitalize.py" 2>/dev/null; then
    say "        processus autocapitalize.py arrêté"
fi

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
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    say "        agent chargé (launchctl print OK)"
else
    say "        agent NON chargé — lancer : \"$BIN\" --status"
fi
if pgrep -f "AutoCap.app/Contents/MacOS/AutoCap" >/dev/null 2>&1; then
    say "        processus en cours (pid $(pgrep -f 'AutoCap.app/Contents/MacOS/AutoCap' | head -1))"
else
    say "        processus non détecté (il attend peut-être l'autorisation)"
fi
if [ -f "$HOME/Library/Logs/autocap.log" ]; then
    say "        dernières lignes du journal :"
    tail -6 "$HOME/Library/Logs/autocap.log" 2>/dev/null | sed 's/^/[install]           /'
else
    say "        (journal pas encore créé)"
fi

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

  2. Si le journal mentionne « Input Monitoring », faire de même dans
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
