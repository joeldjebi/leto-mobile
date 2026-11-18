import 'package:flutter/material.dart';

import 'api.dart';
import 'notifications.dart';
import 'screens/client_home.dart';
import 'screens/driver_home.dart';
import 'screens/independent_screens.dart';
import 'screens/login_screen.dart';
import 'screens/onboarding.dart';
import 'theme.dart';

export 'theme.dart'
    show
        accent,
        accentDeep,
        accentLight,
        ink,
        letoGradient,
        letoOrange,
        Motion,
        Palette,
        TextStyles;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LetoNotifier.instance.init();
  await Api.instance.restore();
  // Dev uniquement : connexion auto avec --dart-define=DEV_PHONE=... --dart-define=DEV_PASSWORD=...
  const devPhone = String.fromEnvironment('DEV_PHONE');
  if (devPhone.isNotEmpty) {
    await Api.instance.logout();
    try {
      await Api.instance.login(
        devPhone,
        const String.fromEnvironment('DEV_PASSWORD'),
      );
    } catch (_) {}
  }
  loadMapStyle(); // fond de carte choisi par le SA (sans bloquer le démarrage)
  runApp(const LetoApp());
}

/// Dev / tests : forcer le thème avec --dart-define=THEME=dark|light
const _forcedTheme = String.fromEnvironment('THEME');

class LetoApp extends StatelessWidget {
  const LetoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LETO',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: switch (_forcedTheme) {
        'dark' => ThemeMode.dark,
        'light' => ThemeMode.light,
        _ => ThemeMode.system,
      },
      // Dev / tests : SKIP_SPLASH=true ouvre directement l'accueil
      home: const bool.fromEnvironment('SKIP_SPLASH') ? homeFor() : const SplashScreen(),
      // Grands caractères du téléphone : suivis, mais bornés pour garder des écrans lisibles et sans débordement
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(
            textScaler: mq.textScaler.clamp(
              minScaleFactor: 0.9,
              maxScaleFactor: 1.2,
            ),
          ),
          child: child!,
        );
      },
    );
  }
}

/// Écran d'accueil selon le rôle de l'utilisateur connecté
Widget homeFor() {
  final api = Api.instance;
  if (!api.isLoggedIn) return const LoginScreen();
  // Notifications locales par le temps réel (autorisation demandée une fois)
  LetoNotifier.instance.requestPermission();
  LetoNotifier.instance.attach();
  if (api.isIndependent) return const IndependentGate();
  return api.role == 'DRIVER' ? const DriverHome() : const ClientHome();
}

/// Remplace toute la pile de navigation (après connexion / déconnexion)
void goHome(BuildContext context) {
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => homeFor()),
    (_) => false,
  );
}

void showError(BuildContext context, Object e) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(e.toString()),
        backgroundColor: Palette.of(context).red,
      ),
    );
}

void showInfo(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}
