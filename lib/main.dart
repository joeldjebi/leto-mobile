import 'package:flutter/material.dart';

import 'api.dart';
import 'screens/client_home.dart';
import 'screens/driver_home.dart';
import 'screens/login_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Api.instance.restore();
  // Dev uniquement : connexion auto avec --dart-define=DEV_PHONE=... --dart-define=DEV_PASSWORD=...
  const devPhone = String.fromEnvironment('DEV_PHONE');
  if (devPhone.isNotEmpty) {
    await Api.instance.logout();
    try {
      await Api.instance.login(devPhone, const String.fromEnvironment('DEV_PASSWORD'));
    } catch (_) {}
  }
  runApp(const LetoApp());
}

const letoOrange = Color(0xFFF77F00);
const letoGreen = Color(0xFF009E60);
const letoDark = Color(0xFF1D2330);

class LetoApp extends StatelessWidget {
  const LetoApp({super.key});

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
    return MaterialApp(
      title: 'LETO',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: letoOrange, primary: letoOrange),
        scaffoldBackgroundColor: Colors.white,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: letoDark,
          elevation: 0,
          titleTextStyle: TextStyle(color: letoDark, fontSize: 20, fontWeight: FontWeight.bold),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(54),
            shape: shape,
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50), shape: shape),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF3F4F6),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        ),
      ),
      home: homeFor(),
    );
  }
}

/// Écran d'accueil selon le rôle de l'utilisateur connecté
Widget homeFor() {
  final api = Api.instance;
  if (!api.isLoggedIn) return const LoginScreen();
  return api.role == 'DRIVER' ? const DriverHome() : const ClientHome();
}

/// Remplace toute la pile de navigation (après connexion / déconnexion)
void goHome(BuildContext context) {
  Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => homeFor()), (_) => false);
}

void showError(BuildContext context, Object e) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(e.toString()), backgroundColor: Colors.red.shade700),
  );
}

void showInfo(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}
