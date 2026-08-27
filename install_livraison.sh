#!/bin/bash
# ============================================================
# install_livraison.sh — installe l'agent de livraison auto-nettoyant
#   • Copie livraison-sync.sh dans ~/Scripts/
#   • Installe le LaunchAgent com.jarvis.livraison (toutes les 5 s, 24/7)
#   • Nettoie le verrou périmé
# À exécuter SUR LE MAC. Une seule commande (récupéré via curl GitHub).
# ============================================================
set -u

SCRIPTS_DIR="$HOME/Scripts"
SYNC_SCRIPT="$SCRIPTS_DIR/livraison-sync.sh"
LA_DIR="$HOME/Library/LaunchAgents"
PLIST="$LA_DIR/com.jarvis.livraison.plist"
LOCK_DIR="$HOME/.livraison.lock"

echo "==> Installation agent de livraison auto-nettoyant"

mkdir -p "$SCRIPTS_DIR" "$LA_DIR"

# ---- Nettoyage du verrou périmé ----
if [ -d "$LOCK_DIR" ] && [ -n "$(find "$LOCK_DIR" -mmin +1 2>/dev/null)" ]; then
    rmdir "$LOCK_DIR" 2>/dev/null && echo "    Verrou périmé supprimé."
fi

# ---- Copie du script agent (livré par ce même installateur) ----
# Le script livraison-sync.sh doit être à côté de cet installateur
# (téléchargé ensemble depuis GitHub, ou présent dans le même dossier).
SRC="$(dirname "$0")/livraison-sync.sh"
if [ ! -f "$SRC" ]; then
    # Fallback : téléchargement depuis GitHub
    curl -fsSL "https://raw.githubusercontent.com/Spymack/autocapitalize/main/livraison-sync.sh" -o "$SYNC_SCRIPT" || { echo "ERREUR : livraison-sync.sh introuvable (ni local ni GitHub)."; exit 1; }
else
    cp "$SRC" "$SYNC_SCRIPT"
fi
chmod +x "$SYNC_SCRIPT"
echo "    Script agent : $SYNC_SCRIPT"

# ---- Arrêt de l'ancien agent ----
launchctl unload "$PLIST" 2>/dev/null || true

# ---- Nouveau plist (script dédié, plus de one-liner) ----
cat > "$PLIST" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.jarvis.livraison</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Users/aurel/Scripts/livraison-sync.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>5</integer>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
XML
# Note : le chemin absolu /Users/aurel est celui du compte utilisateur.
# Si le nom du compte diffère, remplacer ci-dessus.
launchctl load -w "$PLIST"
echo "    Agent chargé (persistant au reboot)."

# ---- Vérification ----
echo "--- LaunchAgents ---"
launchctl list | grep "com.jarvis.livraison" || echo "PAS CHARGÉ"

echo "--- Test SSH + premier cycle ---"
if ssh -o BatchMode=yes -o ConnectTimeout=8 root@76.13.44.73 true 2>/dev/null; then
    echo "SSH OK. Exécution d'un cycle manuel pour vérifier..."
    bash "$SYNC_SCRIPT"
    echo "Exit : $?"
else
    echo "SSH KO — vérifier la clé (ssh-copy-id root@76.13.44.73)."
fi

echo ""
echo "=== TERMINÉ ==="
echo "L'agent tourne toutes les 5 s : rsync -> vérif -> notification -> nettoyage VPS."
echo "Log : ~/Library/Logs/livraison.log"
echo "Si rien n'arrive : Réglages Système > Confidentialité et sécurité > Accès complet"
echo "au disque -> ajouter /bin/bash et /usr/bin/rsync, puis redémarrer (TCC)."
