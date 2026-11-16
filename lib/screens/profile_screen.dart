import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../main.dart';
import 'widgets.dart';

/// Mon profil : nom, type de compte (clients), numéro et mot de passe
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final api = Api.instance;
  late final Map<String, dynamic> _user = api.user ?? {};
  late final _name = TextEditingController(text: _user['name']);
  late final _phone = TextEditingController(text: _user['phone']);
  late String? _accountType = _user['accountType'];
  final _current = TextEditingController();
  final _newPassword = TextEditingController();
  bool _saving = false;

  bool get _isClient => _user['role'] == 'CLIENT';
  bool get _phoneChanged => _phone.text.trim() != _user['phone'];
  bool get _needsPassword => _phoneChanged || _newPassword.text.isNotEmpty;

  Future<void> _save() async {
    final name = _name.text.trim();
    final phone = _phone.text.trim();
    if (name.isEmpty) return showError(context, 'Indiquez votre nom');
    if (!RegExp(r'^0\d{9}$').hasMatch(phone)) {
      return showError(context, 'Téléphone invalide (10 chiffres)');
    }
    if (_newPassword.text.isNotEmpty && _newPassword.text.length < 6) {
      return showError(context, 'Nouveau mot de passe : 6 caractères minimum');
    }
    if (_needsPassword && _current.text.isEmpty) {
      return showError(
        context,
        'Saisissez votre mot de passe actuel pour changer de numéro ou de mot de passe',
      );
    }
    setState(() => _saving = true);
    try {
      await api.updateProfile({
        'name': name,
        if (_phoneChanged) 'phone': phone,
        if (_isClient && _accountType != null) 'accountType': _accountType,
        if (_newPassword.text.isNotEmpty) 'newPassword': _newPassword.text,
        if (_needsPassword) 'currentPassword': _current.text,
      });
      hapticSuccess();
      if (!mounted) return;
      showInfo(context, 'Profil mis à jour');
      Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final shop = _accountType == 'SHOP';
    return LargeTitlePage(
      title: 'Mon profil',
      bottomBar: GlassBottomBar(
        child: FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const CupertinoActivityIndicator(color: Colors.white)
              : const Text('Enregistrer'),
        ),
      ),
      children: [
        Center(
          child: Avatar(_name.text.isEmpty ? '?' : _name.text, radius: 40),
        ),
        const SizedBox(height: 22),
        if (_isClient)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 22),
            child: CupertinoSlidingSegmentedControl<String>(
              groupValue: _accountType,
              onValueChanged: (v) => setState(() => _accountType = v),
              children: {
                'INDIVIDUAL': Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'Particulier',
                    style: TextStyles.subheadline.copyWith(
                      color: p.label,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                'SHOP': Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'Boutique',
                    style: TextStyles.subheadline.copyWith(
                      color: p.label,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              },
            ),
          ),
        InsetGroup(
          header: 'Informations',
          footer:
              'Ce nom et ce numéro sont donnés au livreur comme expéditeur de vos colis.',
          children: [
            GroupField(
              controller: _name,
              placeholder: shop ? 'Nom de la boutique' : 'Votre nom',
              icon: shop ? CupertinoIcons.bag : CupertinoIcons.person,
              onChanged: (_) => setState(() {}),
            ),
            GroupField(
              controller: _phone,
              placeholder: 'Téléphone',
              prefix: '+225',
              keyboardType: TextInputType.phone,
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
        InsetGroup(
          header: 'Mot de passe',
          footer: _needsPassword
              ? 'Votre mot de passe actuel est demandé pour confirmer ce changement.'
              : 'Laissez vide pour garder le mot de passe actuel.',
          children: [
            GroupField(
              controller: _newPassword,
              placeholder: 'Nouveau mot de passe',
              icon: CupertinoIcons.lock,
              obscure: true,
              onChanged: (_) => setState(() {}),
            ),
            if (_needsPassword)
              GroupField(
                controller: _current,
                placeholder: 'Mot de passe actuel',
                icon: CupertinoIcons.lock_shield,
                obscure: true,
              ),
          ],
        ),
      ],
    );
  }
}
