import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../main.dart';
import 'independent_screens.dart';
import 'widgets.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _registerMode = false;
  String _accountType = 'INDIVIDUAL';
  bool _loading = false;
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();

  /// Inscriptions des livreurs indépendants ouvertes par LETO ?
  bool _independentsOpen = false;

  @override
  void initState() {
    super.initState();
    Api.instance
        .independentsInfo()
        .then((i) {
          if (mounted) {
            setState(() => _independentsOpen = i['registrationOpen'] == true);
          }
        })
        .catchError((_) {});
  }

  Future<void> _submit() async {
    setState(() => _loading = true);
    try {
      final api = Api.instance;
      if (_registerMode) {
        await api.register(
          _name.text.trim(),
          _phone.text.trim(),
          _password.text,
          _accountType,
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
      // Le bouton principal reste visible au-dessus du clavier pendant la saisie
      bottomNavigationBar: GlassBottomBar(
        child: FilledButton(
          onPressed: _loading ? null : _submit,
          child: _loading
              ? const CupertinoActivityIndicator(color: Colors.white)
              : Text(_registerMode ? 'Créer mon compte' : 'Continuer'),
        ),
      ),
      body: SafeArea(
        bottom: false,
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
            AnimatedSize(
              duration: Motion.medium,
              curve: Motion.curve,
              child: _registerMode
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(left: 16, bottom: 8),
                            child: Text(
                              'VOUS ÊTES',
                              style: TextStyles.footnote.copyWith(
                                color: p.secondaryLabel,
                              ),
                            ),
                          ),
                          Row(
                            children: [
                              Expanded(
                                child: _typeCard(
                                  'INDIVIDUAL',
                                  CupertinoIcons.person_fill,
                                  'Particulier',
                                  'J’envoie des colis',
                                  p,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _typeCard(
                                  'SHOP',
                                  CupertinoIcons.bag_fill,
                                  'Boutique',
                                  'Je livre mes clients',
                                  p,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
            InsetGroup(
              header: _registerMode ? 'Créer un compte' : 'Connexion',
              footer: _registerMode
                  ? 'Vous pourrez envoyer des colis à un ou plusieurs destinataires.'
                  : 'Livreurs d’entreprise : votre compte est créé par votre entreprise.',
              children: [
                if (_registerMode)
                  GroupField(
                    controller: _name,
                    placeholder: _accountType == 'SHOP'
                        ? 'Nom de la boutique'
                        : 'Votre nom',
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

            CupertinoButton(
              onPressed: () => setState(() => _registerMode = !_registerMode),
              child: Text(
                _registerMode
                    ? 'J’ai déjà un compte'
                    : 'Nouveau ? Créer un compte',
                style: TextStyles.body.copyWith(color: accent),
              ),
            ),
            if (_independentsOpen && !_registerMode)
              CupertinoButton(
                onPressed: () => Navigator.push(
                  context,
                  CupertinoPageRoute(
                    builder: (_) => const IndependentSignupScreen(),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.two_wheeler, size: 20, color: p.secondaryLabel),
                    const SizedBox(width: 6),
                    Text(
                      'Devenir livreur indépendant',
                      style: TextStyles.subheadline.copyWith(
                        color: p.secondaryLabel,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Choix du type de compte (particulier / boutique)
  Widget _typeCard(
    String type,
    IconData icon,
    String title,
    String subtitle,
    Palette p,
  ) {
    final on = _accountType == type;
    return Pressable(
      onTap: () {
        hapticTap();
        setState(() => _accountType = type);
      },
      child: AnimatedContainer(
        duration: Motion.medium,
        curve: Motion.curve,
        padding: const EdgeInsets.all(14),
        decoration: ShapeDecoration(
          color: on ? p.accentSoft : p.card,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(
              color: on ? accent : p.separator,
              width: on ? 1.6 : 1,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: on ? accent : p.secondaryLabel, size: 24),
            const SizedBox(height: 8),
            Text(title, style: TextStyles.headline.copyWith(color: p.label)),
            Text(
              subtitle,
              style: TextStyles.footnote.copyWith(color: p.secondaryLabel),
            ),
          ],
        ),
      ),
    );
  }
}
