import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../main.dart';
import 'widgets.dart';

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
      hapticSuccess();
      if (mounted) goHome(context);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      backgroundColor: p.background,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(top: 56, bottom: 24),
          children: [
            Center(
              child: Container(
                width: 92,
                height: 92,
                decoration: ShapeDecoration(
                  gradient: const LinearGradient(
                    colors: [accentLight, accent],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  shape: RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  shadows: const [
                    BoxShadow(
                      color: Color(0x406D28D9),
                      blurRadius: 24,
                      offset: Offset(0, 10),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.two_wheeler,
                  color: Colors.white,
                  size: 52,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'LETO',
              textAlign: TextAlign.center,
              style: TextStyles.largeTitle.copyWith(color: p.label),
            ),
            const SizedBox(height: 4),
            Text(
              'Livraison rapide à Abidjan',
              textAlign: TextAlign.center,
              style: TextStyles.body.copyWith(color: p.secondaryLabel),
            ),
            const SizedBox(height: 36),
            InsetGroup(
              header: _registerMode ? 'Créer un compte' : 'Connexion',
              footer: _registerMode
                  ? 'Particulier ou boutique : vous pourrez envoyer des colis à un ou plusieurs destinataires.'
                  : 'Livreurs : votre compte est créé par votre entreprise.',
              children: [
                if (_registerMode)
                  GroupField(
                    controller: _name,
                    placeholder: 'Nom ou nom de la boutique',
                    icon: CupertinoIcons.person,
                  ),
                GroupField(
                  controller: _phone,
                  placeholder: '07 01 02 03 04',
                  prefix: '+225',
                  keyboardType: TextInputType.phone,
                ),
                GroupField(
                  controller: _password,
                  placeholder: 'Mot de passe',
                  icon: CupertinoIcons.lock,
                  obscure: true,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FilledButton(
                onPressed: _loading ? null : _submit,
                child: _loading
                    ? const CupertinoActivityIndicator(color: Colors.white)
                    : Text(_registerMode ? 'Créer mon compte' : 'Continuer'),
              ),
            ),
            const SizedBox(height: 8),
            CupertinoButton(
              onPressed: () => setState(() => _registerMode = !_registerMode),
              child: Text(
                _registerMode
                    ? 'J’ai déjà un compte'
                    : 'Nouveau ? Créer un compte',
                style: TextStyles.body.copyWith(color: accent),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
