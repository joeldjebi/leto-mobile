# Live Activity VITE (iPhone)

Le code de l'extension est prêt dans `LetoLiveActivity.swift`. Il reste à créer la cible dans Xcode (une seule fois) :

1. Ouvrir `ios/Runner.xcworkspace` dans Xcode.
2. File › New › Target… › **Widget Extension**. Nom : `LetoLive`. Cocher **Include Live Activity**, décocher « Include Configuration App Intent ». Activer le schéma si Xcode le propose.
3. Supprimer les fichiers Swift générés par Xcode dans le dossier `LetoLive`, puis glisser `ios/LetoLive/LetoLiveActivity.swift` dans la cible `LetoLive` (cocher seulement cette cible).
4. Cible **LetoLive** › General › Minimum Deployments : **iOS 16.1**.
5. Cibles **Runner** ET **LetoLive** › Signing & Capabilities › **+ Capability › App Groups** › ajouter `group.ci.leto.leto` (le même pour les deux).
6. Product › Build. Puis `flutter run` comme d'habitude.

Sur le téléphone : Réglages › VITE › Activités en direct doit être activé.
