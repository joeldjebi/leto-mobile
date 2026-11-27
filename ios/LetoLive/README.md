# Live Activity VITE (iPhone)

Extension `LetoLive` (cible Xcode déjà créée) : écran verrouillé et Dynamic Island pendant une course.
Les données viennent de l'app (`lib/live_activity.dart`, plugin live_activities) via le groupe d'apps
`group.ci.leto.leto`, déclaré dans `Runner/Runner.entitlements` et `LetoLive/LetoLive.entitlements`.

Au premier build signé sur un iPhone, Xcode (signature automatique, équipe T6Y62WJ9M7) enregistre
l'identifiant `ci.leto.leto.LetoLive` et le groupe d'apps. Sur le téléphone : Réglages › VITE ›
Activités en direct doit être activé.
