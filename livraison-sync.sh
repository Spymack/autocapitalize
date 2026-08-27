#!/bin/bash
# ============================================================
# livraison-sync.sh — agent de livraison VPS -> Desktop
#   Tourne toutes les 5 s via launchd (com.jarvis.livraison).
#
#   Flux : rsync du VPS vers ~/Desktop
#        -> vérifie que chaque fichier est bien arrivé (taille)
#        -> notification macOS "fichier livré"
#        -> ACK : supprime les fichiers CONFIRMÉS côté VPS
#        -> le tick suivant ne recopie plus rien (définitif)
# ============================================================
set -u

VPS="root@76.13.44.73"
REMOTE_DIR="/workspace/livraison"
DESKTOP="$HOME/Desktop"
LOCK="$HOME/.livraison.lock"
LOG="$HOME/Library/Logs/livraison.log"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10"
RSYNC_SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null || true; }

# ---- Verrou (avec nettoyage périmé : un lock > 1 min = run mort) ----
if [ -d "$LOCK" ] && [ -n "$(find "$LOCK" -mmin +1 2>/dev/null)" ]; then
    rmdir "$LOCK" 2>/dev/null || true
fi
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# ---- 1. Lister les fichiers présents côté VPS ----
REMOTE_FILES=$(ssh $SSH_OPTS "$VPS" "ls -1 '$REMOTE_DIR' 2>/dev/null" 2>/dev/null) || exit 0
if [ -z "$REMOTE_FILES" ]; then
    exit 0                       # rien à livrer
fi

# ---- 2. Rsync VPS -> Desktop ----
if ! /usr/bin/rsync -az --partial --exclude='.DS_Store' \
        -e "$RSYNC_SSH" "$VPS:$REMOTE_DIR/" "$DESKTOP/" 2>/dev/null; then
    log "ERREUR rsync"
    exit 0                       # on réessaiera au prochain tick
fi

# ---- 3. Vérifier que chaque fichier est bien arrivé (présence + taille) ----
CONFIRMED=""
while IFS= read -r f; do
    [ -z "$f" ] && continue
    # Taille côté VPS (source de vérité) et côté Desktop (après rsync)
    REMOTE_SIZE=$(ssh $SSH_OPTS "$VPS" "stat -f%z '$REMOTE_DIR/$f' 2>/dev/null" 2>/dev/null)
    LOCAL_SIZE=$(stat -f%z "$DESKTOP/$f" 2>/dev/null || echo "")
    if [ -n "$REMOTE_SIZE" ] && [ "$REMOTE_SIZE" = "$LOCAL_SIZE" ]; then
        CONFIRMED="$CONFIRMED $f"
    else
        log "non confirmé: $f (remote=$REMOTE_SIZE local=$LOCAL_SIZE)"
    fi
done <<< "$REMOTE_FILES"

if [ -z "$CONFIRMED" ]; then
    exit 0
fi

# ---- 4. ACK : supprimer les fichiers confirmés côté VPS (définitif) ----
for f in $CONFIRMED; do
    # shell-quote pour les noms avec espaces
    Q=$(printf '%q' "$f")
    ssh $SSH_OPTS "$VPS" "cd '$REMOTE_DIR' && rm -f -- $Q" 2>/dev/null || true
done

# ---- 5. Notification macOS ----
LIST=$(echo "$CONFIRMED" | tr ' ' '\n' | sed '/^$/d' | paste -sd ', ' -)
osascript -e "display notification \"$LIST\" with title \"📥 Livraison\" subtitle \"fichier(s) arrivé(s) sur le Bureau\"" 2>/dev/null || true
log "livrés: $CONFIRMED"
