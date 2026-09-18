# autocapitalize

Démon macOS de capitalisation automatique en arrière-plan (fichier unique).

## Règles

- **CASE 2** — début de ligne / champ vide / ligne vide / puce de liste → majuscule
- **CASE 1** — après `.`, `!`, `?`, `…` suivi d'au moins un espace ou une ponctuation → majuscule
- Jamais après Tab, jamais sur une lettre collée au symbole (`Test.p`, `3.14`), jamais sur les abréviations (`etc. `, `M. `, `e.g. `, `J. `), jamais sur les numérotations (`1. `, `42. `), jamais dans les champs sécurisés.

## Architecture

- **Shadow buffer** synchrone : modèle du texte avant le curseur, mis à jour dans le tap pour chaque insertion/suppression (y compris Option/Cmd+Backspace).
- **Lecture AX déclenchée par les événements** : chaque frappe arme une relecture 12 ms plus tard et l'AXObserver signale les changements du champ. Le minuteur n'est plus qu'un filet de sécurité lent (250 ms quand un champ a le focus, 1 s sinon) — il relisait auparavant l'API Accessibilité 50 fois par seconde en permanence, seule opération vraiment coûteuse du démon (6,8× à 10,4× moins de lectures mesurées). Détection des lectures figées (fingerprint), en retard (lag), et point d'insertion obligatoire (jamais deviné).
- **CRITIQUE** : l'API Accessibilité n'est JAMAIS appelée dans le callback du tap (freeze système).
- **Auto-mesure et plafond mémoire** : une ligne par minute dans `~/Library/Logs/autocapitalize-stats.log` (taille résidente, lectures AX, objets retenus, taps/observers reconstruits). Au-delà de 220 Mo pendant 3 mesures consécutives, le démon se relance en place (`os.execv` : même binaire, donc l'autorisation Accessibilité survit).

## Installation

```bash
python3 -m venv ~/Scripts/.autocap-venv
~/Scripts/.autocap-venv/bin/pip install pyobjc-framework-Quartz pyobjc-framework-ApplicationServices pyobjc-framework-Cocoa
~/Scripts/.autocap-venv/bin/python autocapitalize.py --install
```

Puis donner Accessibilité + Surveillance de l'entrée au Python du venv (chemin affiché par `--install`).

## Commandes

| Commande | Effet |
|---|---|
| `--install` | Crée le LaunchAgent `com.local.autocap` et le démarre |
| `--uninstall` | Arrête et supprime le LaunchAgent |
| `--status` | État du service |
| `--selftest` | Vérifie le moteur de règles (107 cas) |
| `--stats` | Derniers échantillons mémoire du démon |
| `--debug` | Premier plan + trace des décisions |
| `--run` | Premier plan (debug) |

## Versions

- **v18** (2026-09-18) : fuite mémoire corrigée. (1) lecture AX déclenchée par les événements au lieu du poll 50 Hz permanent ; (2) `detach_observer()` retire les notifications, invalide la source du run loop et libère l'observateur avant d'en attacher un autre — un observateur vivant et sa connexion mach fuyaient à chaque changement d'application ; (3) `create_tap()` désactive et invalide le tap précédent — chaque recréation par le watchdog fuyait un tap et son port mach. Ajout de `--stats`, de l'auto-mesure et du recyclage au plafond mémoire. selftest 107/107.
- **v17** (2026-08-26) : `should_capitalize()` scindé en `capitalize_reason()` + `can_trust_line_start()` + `resolve_capitalization()` ; le motif « début de ligne » exige un tampon non synthétique (correctif du faux majuscule TAB/DEL/DEL/ESPACE). selftest 101/101.
- **v16** : correctif Tab/complétion, liste d'applications exclues, AXObserver, watchdog du tap, faulthandler, gestion des signaux, garde dead keys/IME.
- **v15** : correctif SIGABRT (exceptions ObjC).
- **v14** : correctif SIGSEGV (`AXValueGetType`), `_KEEP_ALIVE`, `--axprobe`.
- **v11-v13** : détection des lectures AX en retard, garde `EDIT_GUARD`, confiance AX, ponctuation fermante sautable.
- **v1-v10** : évolution du moteur de règles et du shadow buffer.
