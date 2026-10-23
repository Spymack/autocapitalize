# AutoCap — capitalisation automatique pour macOS, 100 % Swift

Remplace le démon Python (`autocapitalize.py`, v20.12). Un binaire unique,
aucun interpréteur, aucune dépendance, aucune autorisation qui se perd à chaque
mise à jour.

## Installation (une seule commande, sur le Mac)

```bash
curl -fsSL -o /tmp/autocap-install.sh "https://raw.githubusercontent.com/Spymack/autocapitalize/main/swift/install.sh" && bash /tmp/autocap-install.sh
```

Le script compile, teste, refuse d'installer si un cas de conformité échoue,
désactive l'ancien démon Python, installe l'agent launchd et affiche un verdict.
Il ne reste ensuite qu'à accorder l'autorisation Accessibilité (un geste, guidé).

## Ce qui change vraiment

| Avant (Python) | Maintenant (Swift) |
|---|---|
| Le tampon local **devinait** le curseur | Le curseur est **mesuré** dans le texte de l'application (alignement avant/après édition) |
| Lectures AX en retard, figées, pré-suppression : trois familles d'heuristiques | Une seule règle : une édition est un segment qui change, l'alignement le localise |
| Curseur illisible dans Chromium → aucune règle applicable | L'alignement rend le curseur mesurable là où la plateforme ne le publie pas |
| Interpréteur dans un venv : autorisation à refaire, plantages Python | Application signée, identité stable, binaire unique |
| Exceptions avalées par `except BaseException` | Erreurs de compilation : la classe de bugs a disparu |
| Plafond mémoire, recyclage par `execv` | Pas de ramasse-miettes, pas de fuite connue ; taille résidente suivie |

## Architecture

```
Sources/
  Core/Rules.swift       décision pure : ce qui ouvre une phrase (188 cas hérités)
  Core/Align.swift       mesure du curseur dans le texte de l'application
  Core/SelfTest.swift    suite de conformité (144 cas) — tourne sans Mac
  Mac/AX.swift           Accessibility : champ focalisé, texte, curseur
  Mac/Tap.swift          CGEventTap + chien de garde
  Mac/Daemon.swift       machine à états, modèle, lectures différées, journal
  Mac/Log.swift          journal avec rotation + empreinte binaire
  Mac/Doctor.swift       --doctor, --probe
  Mac/Install.swift      LaunchAgent
  main.swift             CLI
```

Règle absolue conservée : **l'API Accessibilité n'est jamais appelée dans le
callback du tap** (gel du flux d'événements système).

## Commandes

| Commande | Effet |
|---|---|
| `--doctor` | Diagnostic complet, verdict + code de sortie (0 = prêt) |
| `--selftest` | Suite de conformité (règles, confiance, mesure du curseur) |
| `--status` | État de l'agent, plist, dernières lignes du journal |
| `--probe` | Décrit le champ focalisé de chaque application au premier plan |
| `--stats` | Échantillons mémoire et activité (un par minute) |
| `--debug` | Avec `--run` : trace complète, une ligne par événement |
| `--install` / `--uninstall` | Agent launchd |

## Journal

`~/Library/Logs/autocap.log` — rotation à 2 Mo, jamais de troncature.
Trois traces répondent à « pourquoi pas de majuscule ? » :

```
keydown observed: app=… trusted=1 tap=1
capital inserted before 'M' (reason=ender source=measured note=proved caret before='Fin. ')
target unreadable: the field exposes no caret range (role=AXTextArea, 310 char, app=…)
edit could not be measured: … (12 -> 12 char, app=…) : the caret stays unproven until the next edit
```

Chaque condition est écrite **une fois par changement**, jamais une fois par frappe.

## Désinstallation

```bash
"$HOME/Applications/AutoCap.app/Contents/MacOS/AutoCap" --uninstall --remove-permissions
```

Les sources restent dans `~/Scripts/autocap-swift` (recompilables par `build.sh`).
