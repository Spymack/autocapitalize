# autocapitalize

Démon macOS de capitalisation automatique en arrière-plan (fichier unique).

## Règles

- **CASE 2** — début de ligne / champ vide / ligne vide / puce de liste → majuscule
- **CASE 1** — après `.`, `!`, `?`, `…` suivi d'au moins un espace ou une ponctuation → majuscule
- Jamais après Tab, jamais sur une lettre collée au symbole (`Test.p`, `3.14`), jamais sur les abréviations (`etc. `, `M. `, `e.g. `, `J. `), jamais sur les numérotations (`1. `, `42. `), jamais dans les champs sécurisés.

## Architecture

- **Shadow buffer** synchrone : modèle du texte avant le curseur, mis à jour dans le tap pour chaque insertion/suppression (y compris Option/Cmd+Backspace).
- **Polling AX** 20 ms (hors tap) : relit le champ réel, avec détection des lectures figées (fingerprint), en retard (lag), et point d'insertion obligatoire (jamais deviné).
- **CRITIQUE** : l'API Accessibilité n'est JAMAIS appelée dans le callback du tap (freeze système).

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
| `--selftest` | Vérifie le moteur de règles (72 cas) |
| `--debug` | Premier plan + trace des décisions |
| `--run` | Premier plan (debug) |

## Versions

- **v11** (2026-08-19) : détection des lectures AX en retard (`is_lagging_ax_read`), garde `EDIT_GUARD` 150 ms après chaque frappe, scénario de frappe rapide ajouté au selftest (72/72).
- v10 : confiance AX (point d'insertion obligatoire, fingerprint anti-gel, anti-runaway).
- v9 : Return modifiés = début de ligne.
- v8 : ponctuation fermante sautable, retries focus 600 ms.
- v7 : shadow buffer, fausses fins de phrase, dead keys.
- v1-v6 : évolution du moteur de règles.
