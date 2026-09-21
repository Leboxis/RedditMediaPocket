# Arbitrage structuré avec `jev_decide` (Jev 1.13)

Tu disposes de l'outil `jev_decide`, qui utilise Jev 1.13 (TypeSafe) comme moteur
de décision structuré via l'API Decisions d'OpenRouter (`POST /api/alpha/decisions`,
modèle `typesafe/jev-1.13`). Ce n'est PAS un modèle de chat : il ne génère pas de
texte, il renvoie une décision typée (`decision` + `confidence` + `probabilities`).

## Quand l'utiliser

Utilise `jev_decide` lorsque tu dois choisir entre **plusieurs stratégies raisonnables**
et que la décision peut se formaliser en options :
- arbitrer entre plusieurs approches d'implémentation ;
- choisir une stratégie ou la prochaine action face à des alternatives crédibles ;
- comparer des options et départager une incertitude réelle.

N'utilise PAS `jev_decide` pour les tâches triviales, quand une seule option est
raisonnable, ou pour rédiger du code / répondre à l'utilisateur.

## Comment l'appeler

- `question` : la question d'arbitrage en une phrase.
- `state` : l'état factuel précis (code concerné, contraintes de performance,
  compatibilité requise, erreurs observées). Ne mets jamais de secrets ni de clés
  dans `state` : il est envoyé à l'API.
- `choices` : objet `{ "A": "description", "B": "description", ... }` avec au
  moins 2 options. Chaque description doit distinguer l'option des autres.
  Donne toujours une option de repli si aucune ne convient (ex : `"D": "Aucune : ..."`),
  car Jev ne peut choisir qu'une option proposée.

## Après réception de la décision

Tu restes responsable de l'analyse, du code, des outils et de la réponse finale :
1. Vérifie que `decision` est compatible avec le contexte réel du projet.
2. Si `actionable` est `false` ou si `confidence` est faible, Jev dit qu'il ne
   sait pas trancher : affine `state`/`choices` et réessaie, ou tranche toi-même.
3. Exécute ensuite le plan toi-même avec tes outils habituels (read, edit, bash…).
   Jev n'exécute rien.
