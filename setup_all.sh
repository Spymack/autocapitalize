#!/bin/bash
# ============================================================
# setup_all.sh — installer AutoCap sur le Mac en UNE commande
#   • AutoCap (script + venv pyobjc + LaunchAgent com.local.autocap)
#   • Vérifications finales (statut)
# Exécuté SUR LE MAC (récupéré via curl depuis GitHub raw).
# NOTE 2026-08-27 : la partie « livraison Desktop » (com.jarvis.livraison)
# a été retirée à la demande de l'utilisateur (pipeline désinstallé).
# ============================================================
set -u

# Révision à installer : « main » par défaut, ou un sha de commit passé en
# argument. Le CDN de raw.githubusercontent.com peut servir « main » en retard
# pendant plusieurs minutes après un push — et l'installateur télécharge le
# script depuis la MÊME référence que lui-même, sinon la garde anti-périmé
# ci-dessous refuse la révision qu'on vient de publier.
REF="${1:-main}"

SCRIPTS_DIR="$HOME/Scripts"
VENV_DIR="$SCRIPTS_DIR/.autocap-venv"

echo "==> Installation AutoCap — $(sw_vers -productVersion 2>/dev/null || echo 'macOS') [révision $REF]"

# Arrêt immédiat de l'agent existant (arrête la boucle de crash "Python a quitté")
launchctl bootout "gui/$(id -u)/com.local.autocap" 2>/dev/null || true

# ------------------------------------------------------------
# 1. Récupération du script (source GitHub raw)
# ------------------------------------------------------------
echo "==> Récupération du script..."
mkdir -p "$SCRIPTS_DIR"
curl -fsSL "https://raw.githubusercontent.com/Spymack/autocapitalize/$REF/autocapitalize.py" -o "$SCRIPTS_DIR/autocapitalize.py" || { echo "ERREUR : impossible de récupérer le script."; exit 1; }
chmod +x "$SCRIPTS_DIR/autocapitalize.py"
# Garde anti-CDN périmé : raw.githubusercontent.com peut servir une révision
# antérieure pendant plusieurs minutes après un push. Les marqueurs ci-dessous
# datent la révision attendue :
#   needs_ax_poll       -> v18+ (correctif mémoire)
#   enumerator_reason   -> v20  (ligne vide après Maj+Entrée, énumérateurs « 1) », « A) »)
#   static_call_problems -> v20.1 (appel à argument manquant : le garde-fou statique du selftest)
#   callbackFor         -> v20.2 (l'observateur Accessibilité s'attache enfin)
#   report_target       -> v20.3 (raison exacte quand la cible AX est inutilisable)
#   "always written"    -> v20.4 (cette raison est écrite dans le journal sans --debug)
#   "Return observed"   -> v20.5 (traces Retour / majuscule insérée / touche sans caractère)
#   "read that COMPLETES" -> v20.6 (une raison persistante n'est signalée qu'une fois)
#   "keydown observed"  -> v20.7 (le tap prouve qu'il reçoit les frappes ; une raison
#                          persistante reste UNE ligne ; un échec de callback n'est
#                          plus jamais silencieux)
#   anchor_survives_vertical -> v20.8 (une flèche Haut ne capitalise plus quand la
#                          ligne du dessus porte du texte : elle pouvait écrire une
#                          majuscule au milieu d'une phrase)
#   may_arm_from_shadow -> v20.9 (un déclencheur collé au curseur arme après une
#                          suppression ; seul « début de texte » attend la
#                          confirmation Accessibilité)
#   buffer_after_multi_deletion -> v20.10 (un Suppr sur une SÉLECTION est
#                          dimensionné par la longueur du texte annoncée par
#                          l'application, visible même quand le curseur ne l'est pas)
if ! grep -q "needs_ax_poll" "$SCRIPTS_DIR/autocapitalize.py"; then
    echo "ERREUR : révision périmée reçue (correctif mémoire absent). Réessayer dans 1 minute."
    exit 1
fi
if ! grep -q "enumerator_reason" "$SCRIPTS_DIR/autocapitalize.py"; then
    echo "ERREUR : révision périmée reçue (correctif v20 absent). Réessayer dans 1 minute."
    exit 1
fi
if ! grep -q "static_call_problems" "$SCRIPTS_DIR/autocapitalize.py"; then
    echo "ERREUR : révision périmée reçue (correctif v20.1 absent). Réessayer dans 1 minute."
    exit 1
fi
if ! grep -q "callbackFor" "$SCRIPTS_DIR/autocapitalize.py"; then
    echo "ERREUR : révision périmée reçue (correctif v20.2 absent). Réessayer dans 1 minute."
    exit 1
fi
if ! grep -q "report_target" "$SCRIPTS_DIR/autocapitalize.py"; then
    echo "ERREUR : révision périmée reçue (correctif v20.3 absent). Réessayer dans 1 minute."
    exit 1
fi
if ! grep -q "always written" "$SCRIPTS_DIR/autocapitalize.py"; then
    echo "ERREUR : révision périmée reçue (correctif v20.4 absent). Réessayer dans 1 minute."
    exit 1
fi
if ! grep -q "Return observed" "$SCRIPTS_DIR/autocapitalize.py"; then
    echo "ERREUR : révision périmée reçue (correctif v20.5 absent). Réessayer dans 1 minute."
    exit 1
fi
if ! grep -q "read that COMPLETES" "$SCRIPTS_DIR/autocapitalize.py"; then
    echo "ERREUR : révision périmée reçue (correctif v20.6 absent). Réessayer dans 1 minute."
    exit 1
fi
if ! grep -q "keydown observed" "$SCRIPTS_DIR/autocapitalize.py"; then
    echo "ERREUR : révision périmée reçue (correctif v20.7 absent). Réessayer dans 1 minute."
    exit 1
fi
if ! grep -q "anchor_survives_vertical" "$SCRIPTS_DIR/autocapitalize.py"; then
    echo "ERREUR : révision périmée reçue (correctif v20.8 absent). Réessayer dans 1 minute."
    exit 1
fi
if ! grep -q "may_arm_from_shadow" "$SCRIPTS_DIR/autocapitalize.py"; then
    echo "ERREUR : révision périmée reçue (correctif v20.9 absent). Réessayer dans 1 minute."
    exit 1
fi
if ! grep -q "buffer_after_multi_deletion" "$SCRIPTS_DIR/autocapitalize.py"; then
    echo "ERREUR : révision périmée reçue (correctif v20.10 absent). Réessayer dans 1 minute."
    exit 1
fi

# ------------------------------------------------------------
# 2. Environnement Python (venv + pyobjc)
#    IMPORTANT : ne JAMAIS forcer pip install --upgrade pyobjc —
#    un upgrade incompatible avec le macOS fait planter le daemon
#    (fenêtre "Python a quitté de manière imprévue").
#    Si l'import de Quartz crash, on reconstruit un venv propre.
# ------------------------------------------------------------
echo "==> Environnement Python (venv + pyobjc)..."
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERREUR : python3 introuvable. Installer les outils développeur (xcode-select --install)."
    exit 1
fi
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
fi
echo "    Test import Quartz..."
if ! "$VENV_DIR/bin/python" -c "import Quartz; import ApplicationServices" >/dev/null 2>&1; then
    echo "    Import Quartz défaillant — reconstruction d'un venv propre (cause probable du crash)..."
    rm -rf "$VENV_DIR"
    python3 -m venv "$VENV_DIR"
fi
"$VENV_DIR/bin/python" -m pip install --upgrade pip --quiet
"$VENV_DIR/bin/python" -m pip install pyobjc-framework-Quartz pyobjc-framework-ApplicationServices pyobjc-framework-Cocoa --quiet
echo "    Vérification finale import Quartz..."
if ! "$VENV_DIR/bin/python" -c "import Quartz; import ApplicationServices; print('Quartz OK')" 2>&1; then
    echo "ERREUR : Quartz ne s'importe toujours pas. Montrer cette sortie à Jarvis."
    exit 1
fi

# ------------------------------------------------------------ #
# 3. Selftest (doit être 169/169)
# ------------------------------------------------------------ #
echo "==> Selftest..."
SELFTEST_OUT=$("$VENV_DIR/bin/python" "$SCRIPTS_DIR/autocapitalize.py" --selftest 2>&1)
echo "$SELFTEST_OUT"
if ! echo "$SELFTEST_OUT" | grep -q "169/169 passed"; then
    echo "ERREUR : selftest incomplet. Montrer la sortie à Jarvis."
    exit 1
fi

# ------------------------------------------------------------
# 4. Installation / redémarrage d'AutoCap
# ------------------------------------------------------------
echo "==> Installation AutoCap (LaunchAgent com.local.autocap)..."
launchctl bootout "gui/$(id -u)/com.local.autocap" 2>/dev/null || true
"$VENV_DIR/bin/python" "$SCRIPTS_DIR/autocapitalize.py" --install
echo "==> Statut AutoCap :"
"$VENV_DIR/bin/python" "$SCRIPTS_DIR/autocapitalize.py" --status || true

# ------------------------------------------------------------ #
# 4a. Quel Python le LaunchAgent lance-t-il RÉELLEMENT ?
#     Le script résout le lien symbolique du venv, donc le plist
#     contient souvent le chemin du Python Homebrew — et c'est ce
#     chemin-là qui porte l'autorisation Accessibilité, puisque TCC
#     suit le binaire réellement exécuté. Le rappeler évite d'aller
#     autoriser un interpréteur qui n'est pas celui qui tourne.
# ------------------------------------------------------------ #
LAUNCHED_PY=$(plutil -extract ProgramArguments.0 raw -o - "$HOME/Library/LaunchAgents/com.local.autocap.plist" 2>/dev/null || true)
if [ -n "$LAUNCHED_PY" ]; then
    echo "==> Python lancé par le LaunchAgent : $LAUNCHED_PY"
    if "$LAUNCHED_PY" -c "import Quartz, ApplicationServices" >/dev/null 2>&1; then
        echo "    Quartz disponible sur cet interpréteur."
    else
        echo "    ATTENTION : Quartz absent de cet interpréteur — montrer cette ligne à Jarvis."
    fi
fi

# ------------------------------------------------------------ #
# 4b. Mesure de départ (l'auto-mesure écrit une ligne par minute
#     dans ~/Library/Logs/autocapitalize-stats.log : --stats les relit)
# ------------------------------------------------------------ #
sleep 3
CAP_PID=$(pgrep -f "autocapitalize.py --run" | head -1)
if [ -n "$CAP_PID" ]; then
    ps -o rss= -p "$CAP_PID" | awk '{printf "==> RAM au démarrage : %.0f Mo\n", $1/1024}'
else
    echo "==> Démon non détecté (voir --status ci-dessus)."
fi

# ------------------------------------------------------------
# 5. Récapitulatif
# ------------------------------------------------------------
rm -f /tmp/setup_all.sh
echo ""
echo "=== TERMINÉ ==="
echo "AutoCap actif : majuscule après .!? et début de ligne (arrêt : launchctl bootout gui/$(id -u)/com.local.autocap)."
echo ""
echo "PERMISSIONS (une seule fois, Réglages Système > Confidentialité et sécurité) :"
echo "  1. Accessibilité  -> ajouter et activer : ${LAUNCHED_PY:-$VENV_DIR/bin/python}"
echo "  2. Surveillance des entrées -> ajouter le même binaire si les frappes ne sont pas interceptées"
echo ""
echo "NOTE : ce chemin vient d'une version précise de Python. Si Homebrew le remplace"
echo "(mise à jour de python@3.14), le démon ne redémarrera plus : relancer cette commande."
