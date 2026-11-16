# LETO — Application mobile (Flutter)

Une seule app pour deux profils :

- **Client** (inspiré de Yango) :
  - accueil : carte, épingle avec « Prise en charge ~X min », recherche de l'adresse de livraison, carrousel d'offres (Moto, Voiture, Cargo), paiement en espèces ;
  - commande : délai (Express, Standard, Dans 2 h), paiement à la livraison, précisions, photos, expéditeur et destinataire, commentaire au coursier.
  - suivi : propositions de prix des livreurs (accepter ou refuser, avec compte à rebours), puis la moto en direct.
- **Livreur** (esprit Yango) : carte plein écran, interrupteur En ligne / Hors ligne, panneau avec les onglets Courses, En cours et Gains. La fiche d'une course montre les itinéraires moi → A et A → B, avec « Accepter pour X F » ou **« Proposez votre prix »** (+10 %, +20 % ou montant libre).
- Paiement de la course : **espèces uniquement**.

Carte : OpenStreetMap via `flutter_map` (sans clé API).

## Temps réel (Socket.IO)

- Le livreur envoie sa position GPS (à chaque déplacement de 10 m, et toutes les 20 s à l'arrêt).
- Le client voit la moto du livreur bouger sur l'écran de suivi, et les changements de statut arrivent instantanément.
- Les livreurs reçoivent les nouvelles courses sans rafraîchir.
- Code : `lib/realtime.dart`. Un rafraîchissement REST périodique reste actif en filet de sécurité.

Notifications push (Firebase) : prévues pour une prochaine étape.

## Démarrer

```bash
flutter pub get
flutter run                                   # API par défaut : localhost (iOS) / 10.0.2.2 (émulateur Android)
flutter run --dart-define=API_URL=http://192.168.1.10:3000   # téléphone réel sur le même Wi-Fi
```

> Les tuiles `tile.openstreetmap.org` conviennent au développement. En production, utilisez un fournisseur de tuiles (MapTiler, Stadia, Mapbox…) ou Google Maps.

### Développement

```bash
# Connexion automatique + position GPS simulée
flutter run --dart-define=DEV_PHONE=0555555555 --dart-define=DEV_PASSWORD=secret12 \
            --dart-define=DEV_LAT=5.36 --dart-define=DEV_LNG=-3.99
```

### Tests de parcours (simulateur)

`integration_test/flow_test.dart` joue les parcours complets avec de vrais appuis et la vraie API :

```bash
flutter test integration_test/flow_test.dart -d <simulateur> --dart-define=FLOW=client \
  --dart-define=DEV_PHONE=0555555555 --dart-define=DEV_PASSWORD=secret12 --dart-define=DEV_LAT=5.36 --dart-define=DEV_LNG=-3.99
# FLOW=driver avec un compte livreur
```
