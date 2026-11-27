# VITE — Application mobile (Flutter)

Une seule app pour deux profils, au **design inspiré des apps Apple** (grands titres, listes groupées, panneaux translucides sur la carte, feuilles d'actions iOS, mode sombre), sur iPhone comme sur Android.

- **Client / boutique** :
  - départ, puis **une ou plusieurs adresses de livraison** (jusqu'à 10) ; l'ordre de passage est optimisé ;
  - **carnet d'adresses** : les destinataires sont mémorisés automatiquement et proposés dans la recherche ;
  - par destinataire : nom, téléphone, précisions, colis, paiement à la livraison, photo ;
  - après la commande : **partage du code** de chaque destinataire sur WhatsApp (directement à son numéro) ou par le partage du système, sans SMS ;
  - suivi : arrêt par arrêt, alertes « livreur sur place » et « livraison impossible » (avec la photo du livreur), possibilité de **contester** ;
  - propositions de prix des livreurs (accepter / refuser) ; paiement en espèces.
- **Livreur** : en ligne / hors ligne, courses disponibles, fiche avec la tournée complète, « Accepter » ou « Proposez votre prix », tournée arrêt par arrêt, code de chaque destinataire, **signalement d'absence vérifié** (présence GPS, attente obligatoire, photo), gains.

Carte : OpenStreetMap via `flutter_map` (sans clé API).

## Temps réel (Socket.IO)

- Le livreur envoie sa position GPS (à chaque déplacement de 10 m, et toutes les 20 s à l'arrêt).
- Le client voit la moto du livreur bouger sur l'écran de suivi, et les changements de statut arrivent instantanément.
- Les livreurs reçoivent les nouvelles courses sans rafraîchir.
- Code : `lib/realtime.dart`. Un rafraîchissement REST périodique reste actif en filet de sécurité.

Notifications push (Firebase) : prévues pour une prochaine étape.

## Démarrer

L'app utilise **l'API de production par défaut** : `https://api.leto.performx.online`.

```bash
flutter pub get
flutter run                                    # API de production
flutter build apk --release                    # Android (production)
flutter build ipa --release                    # iOS (production)

flutter run --dart-define=API_URL=local        # API de votre Mac (localhost, ou 10.0.2.2 sur émulateur Android)
flutter run --dart-define=API_URL=http://192.168.1.10:3000   # téléphone sur le même Wi-Fi que le Mac
```

Le HTTP non chiffré n'est autorisé que vers le réseau local (iOS) et dans les versions de développement (Android).

### Développement

```bash
# Connexion automatique + position GPS simulée (+ THEME=dark|light, DEV_PHOTO=/uploads/x.jpg pour les tests)
flutter run --dart-define=API_URL=local --dart-define=DEV_PHONE=0555555555 --dart-define=DEV_PASSWORD=secret12 \
            --dart-define=DEV_LAT=5.36 --dart-define=DEV_LNG=-3.99
```

### Tests de parcours (simulateur)

`integration_test/flow_test.dart` joue les parcours complets avec de vrais appuis et la vraie API :

```bash
flutter test integration_test/flow_test.dart -d <simulateur> --dart-define=FLOW=client --dart-define=API_URL=local \
  --dart-define=DEV_PHONE=0555555555 --dart-define=DEV_PASSWORD=secret12 --dart-define=DEV_LAT=5.36 --dart-define=DEV_LNG=-3.99
# FLOW=driver (livreur) · FLOW=dispute (contestation) · FLOW=prodcheck (vérifie que l'app joint l'API de production)
```
