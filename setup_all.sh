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

SCRIPTS_DIR="$HOME/Scripts"
VENV_DIR="$SCRIPTS_DIR/.autocap-venv"

echo "==> Installation AutoCap — $(sw_vers -productVersion 2>/dev/null || echo 'macOS')"

# Arrêt immédiat de l'agent existant (arrête la boucle de crash "Python a quitté")
launchctl bootout "gui/$(id -u)/com.local.autocap" 2>/dev/null || true

# ------------------------------------------------------------
# 1. Récupération du script (source GitHub raw)
# ------------------------------------------------------------
echo "==> Récupération du script..."
mkdir -p "$SCRIPTS_DIR"
curl -fsSL "https://raw.githubusercontent.com/Spymack/autocapitalize/main/autocapitalize.py" -o "$SCRIPTS_DIR/autocapitalize.py" || { echo "ERREUR : impossible de récupérer le script."; exit 1; }
chmod +x "$SCRIPTS_DIR/autocapitalize.py"

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

# ------------------------------------------------------------
# 3. Selftest (doit être 101/101)
# ------------------------------------------------------------
echo "==> Selftest..."
SELFTEST_OUT=$("$VENV_DIR/bin/python" "$SCRIPTS_DIR/autocapitalize.py" --selftest 2>&1)
echo "$SELFTEST_OUT"
if ! echo "$SELFTEST_OUT" | grep -q "101/101 passed"; then
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

# ------------------------------------------------------------
# 5. Récapitulatif
# ------------------------------------------------------------
rm -f /tmp/setup_all.sh
echo ""
echo "=== TERMINÉ ==="
echo "AutoCap actif : majuscule après .!? et début de ligne (arrêt : launchctl bootout gui/$(id -u)/com.local.autocap)."
echo ""
echo "PERMISSIONS à accorder (une seule fois, dans Réglages Système > Confidentialité et sécurité) :"
echo "  1. Accessibilité  -> ajouter et activer : $VENV_DIR/bin/python"
echo "  2. Surveillance des entrées -> ajouter le même binaire si les frappes ne sont pas interceptées"
