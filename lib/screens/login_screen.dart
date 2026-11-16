import 'package:flutter/material.dart';

import '../api.dart';
import '../main.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _registerMode = false;
  bool _loading = false;
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();

  Future<void> _submit() async {
    setState(() => _loading = true);
    try {
      final api = Api.instance;
      if (_registerMode) {
        await api.register(
          _name.text.trim(),
          _phone.text.trim(),
          _password.text,
        );
      } else {
        await api.login(_phone.text.trim(), _password.text);
      }
      if (mounted) goHome(context);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: letoOrange,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const Expanded(
              flex: 2,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.delivery_dining, size: 80, color: Colors.white),
                    Text(
                      'LETO',
                      style: TextStyle(
                        fontSize: 44,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                        letterSpacing: 2,
                      ),
                    ),
                    Text(
                      'Livraison rapide à Abidjan',
                      style: TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ],
                ),
              ),
            ),
            Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
              child: SafeArea(
                top: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      _registerMode ? 'Créer un compte' : 'Connexion',
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 20),
                    if (_registerMode) ...[
                      TextField(
                        controller: _name,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                          hintText: 'Votre nom ou nom de boutique',
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      maxLength: 10,
                      decoration: const InputDecoration(
                        hintText: '07 01 02 03 04',
                        counterText: '',
                        prefixIcon: Padding(
                          padding: EdgeInsets.fromLTRB(16, 14, 8, 14),
                          child: Text('+225', style: TextStyle(fontSize: 16)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      decoration: const InputDecoration(
                        hintText: 'Mot de passe',
                        prefixIcon: Icon(Icons.lock_outline),
                      ),
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _loading ? null : _submit,
                      child: _loading
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              _registerMode ? 'Créer mon compte' : 'Continuer',
                            ),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () =>
                          setState(() => _registerMode = !_registerMode),
                      child: Text(
                        _registerMode
                            ? "J'ai déjà un compte"
                            : 'Nouveau ? Créer un compte',
                      ),
                    ),
                    if (!_registerMode)
                      const Text(
                        'Livreurs : votre compte est créé par votre entreprise.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
