#!/bin/bash
# ============================================================
# setup_all.sh — TOUT installer sur le Mac en UNE commande
#   • Clé SSH vers le VPS (si absente, mot de passe root demandé UNE fois)
#   • AutoCap v13 (script + venv pyobjc + LaunchAgent com.local.autocap)
#   • Agent de livraison Desktop (com.jarvis.livraison, rsync toutes les 5 s)
#   • Vérifications finales (LaunchAgents + Desktop)
# Exécuté SUR LE MAC (récupéré via curl depuis GitHub raw).
# ============================================================
set -u

VPS_IP="76.13.44.73"
VPS_ROOT="root@${VPS_IP}"
SCRIPTS_DIR="$HOME/Scripts"
VENV_DIR="$SCRIPTS_DIR/.autocap-venv"
DESKTOP="$HOME/Desktop"
LA_DIR="$HOME/Library/LaunchAgents"
PLIST_LIVRAISON="$LA_DIR/com.jarvis.livraison.plist"

echo "==> Installation AutoCap + Livraison — $(sw_vers -productVersion 2>/dev/null || echo 'macOS')"

# Arrêt immédiat de l'agent existant (arrête la boucle de crash "Python a quitté")
launchctl bootout "gui/$(id -u)/com.local.autocap" 2>/dev/null || true

# ------------------------------------------------------------
# 0. Prérequis : clé SSH vers le VPS
# ------------------------------------------------------------
echo "==> Vérification de la clé SSH vers le VPS..."
if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$VPS_ROOT" true 2>/dev/null; then
    echo "    Clé absente — copie de la clé publique (mot de passe root du VPS demandé UNE fois)"
    mkdir -p "$HOME/.ssh"
    grep -q "$VPS_IP" "$HOME/.ssh/known_hosts" 2>/dev/null || ssh-keyscan -H "$VPS_IP" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
    ssh-copy-id "$VPS_ROOT"
    if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$VPS_ROOT" true 2>/dev/null; then
        echo "ERREUR : SSH vers le VPS toujours impossible après ssh-copy-id."
        exit 1
    fi
fi
echo "    Clé SSH OK."

# ------------------------------------------------------------
# 1. Récupération de la v13 (source VPS = garantie, fallback GitHub)
# ------------------------------------------------------------
echo "==> Récupération de la v13..."
mkdir -p "$SCRIPTS_DIR"
if scp -o BatchMode=yes -o ConnectTimeout=10 "$VPS_ROOT:/workspace/livraison/autocapitalize.py" "$SCRIPTS_DIR/autocapitalize.py" 2>/dev/null; then
    echo "    Copiée depuis le VPS."
else
    echo "    VPS indisponible — téléchargement depuis GitHub raw..."
    curl -fsSL "https://raw.githubusercontent.com/Spymack/autocapitalize/main/autocapitalize.py" -o "$SCRIPTS_DIR/autocapitalize.py" || { echo "ERREUR : impossible de récupérer le script."; exit 1; }
fi
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
# 3. Selftest (le FAIL connu "predeletion: windowed shadow" est acceptable)
# ------------------------------------------------------------
echo "==> Selftest..."
SELFTEST_OUT=$("$VENV_DIR/bin/python" "$SCRIPTS_DIR/autocapitalize.py" --selftest 2>&1)
echo "$SELFTEST_OUT"
OTHER_FAILS=$(echo "$SELFTEST_OUT" | grep "^FAIL" | grep -v "predeletion: windowed shadow" || true)
if [ -n "$OTHER_FAILS" ]; then
    echo "ERREUR : échecs de selftest inattendus."
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
# 5. Agent de livraison Desktop (com.jarvis.livraison)
# ------------------------------------------------------------
echo "==> Installation agent de livraison (com.jarvis.livraison)..."
mkdir -p "$LA_DIR"
launchctl unload "$PLIST_LIVRAISON" 2>/dev/null || true
cat > "$PLIST_LIVRAISON" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.jarvis.livraison</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>mkdir "$HOME/.livraison.lock" 2>/dev/null || exit 0; trap 'rmdir "$HOME/.livraison.lock" 2>/dev/null' EXIT; /usr/bin/rsync -az --partial --exclude='.DS_Store' -e "ssh -o BatchMode=yes -o ConnectTimeout=10" root@76.13.44.73:/workspace/livraison/ "$HOME/Desktop/"</string>
    </array>
    <key>StartInterval</key>
    <integer>5</integer>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
XML
launchctl load -w "$PLIST_LIVRAISON"
echo "    Agent de livraison chargé (persistant au reboot)."

# ------------------------------------------------------------
# 6. Vérifications
# ------------------------------------------------------------
echo "==> Vérifications..."
echo "--- LaunchAgents ---"
launchctl list | grep -E "com\.(local\.autocap|jarvis\.livraison)" || true
echo "--- Desktop (attente 15 s pour la synchro) ---"
sleep 15
if [ -f "$DESKTOP/autocapitalize.py" ]; then
    echo "OK : autocapitalize.py est sur le Desktop."
    ls -la "$DESKTOP/autocapitalize.py"
else
    echo "ATTENTION : le fichier n'est pas encore sur le Desktop."
    echo "    Si le rsync échoue : Réglages Système > Confidentialité et sécurité >"
    echo "    Accès complet au disque > '+' > Cmd+Shift+G > ajouter :"
    echo "      - /bin/bash"
    echo "      - /usr/bin/rsync"
    echo "    Activer les curseurs puis REDÉMARRER le Mac (TCC ne s'applique qu'au reboot)."
fi

# ------------------------------------------------------------
# 7. Nettoyage + récapitulatif
# ------------------------------------------------------------
rm -f /tmp/setup_all.sh
echo ""
echo "=== TERMINÉ ==="
echo "AutoCap v13 actif : majuscule après .!? et début de ligne (arrêt : launchctl bootout gui/$(id -u)/com.local.autocap)."
echo "Livraison Desktop active toutes les 5 s."
echo ""
echo "PERMISSIONS à accorder (une seule fois, dans Réglages Système > Confidentialité et sécurité) :"
echo "  1. Accessibilité  -> ajouter et activer : $VENV_DIR/bin/python"
echo "  2. Surveillance des entrées -> ajouter le même binaire si les frappes ne sont pas interceptées"
echo "  3. Accès complet au disque  -> bash (/bin) et rsync (/usr/bin), puis redémarrer"
