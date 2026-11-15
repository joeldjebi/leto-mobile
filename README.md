# LETO — Application mobile (Flutter)

Une seule app pour deux profils :

- **Client** : carte plein écran, choix du départ puis de l'arrivée avec l'épingle centrale, détails (repères, destinataire), prix, commande, puis suivi en direct (recherche du livreur → livreur trouvé → colis récupéré → livré) avec le code de livraison à transmettre au destinataire.
- **Livreur** : carte des courses disponibles avec leur prix, acceptation, « colis récupéré », puis validation par le code du destinataire.

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

### Connexion automatique (développement)

```bash
flutter run --dart-define=DEV_PHONE=0555555555 --dart-define=DEV_PASSWORD=secret12
```
