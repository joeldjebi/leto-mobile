import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../api.dart';
import '../countries.dart';
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
  late final _phone = PhoneController(_user['phone']);
  late String? _accountType = _user['accountType'];
  late final _plate = TextEditingController(text: _user['plate'] ?? '');
  final _current = TextEditingController();
  final _newPassword = TextEditingController();
  bool _saving = false;
  late String? _avatar = _user['avatarUrl'];
  bool _uploading = false;

  /// Photo de profil : selfie uniquement (caméra frontale, pas de photothèque)
  Future<void> _takeSelfie() async {
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        maxWidth: 800,
        imageQuality: 75,
      );
      if (file == null || !mounted) return;
      setState(() => _uploading = true);
      final url = await api.upload(File(file.path));
      await api.updateProfile({'avatarUrl': url});
      hapticSuccess();
      if (mounted) setState(() => _avatar = url);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  bool get _isClient => _user['role'] == 'CLIENT';

  /// Livreur d'entreprise : il renseigne son immatriculation (celle d'un indépendant vient de son dossier)
  bool get _editsPlate => _user['role'] == 'DRIVER' && !api.isIndependent;
  bool get _phoneChanged =>
      !samePhone(_phone.e164 ?? _phone.text, _user['phone']);
  bool get _needsPassword => _phoneChanged || _newPassword.text.isNotEmpty;

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return showError(context, 'Indiquez votre nom');
    final phoneError = _phone.validate();
    if (phoneError != null) return showError(context, phoneError);
    final phone = _phone.e164!;
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
        if (_editsPlate && _plate.text.trim() != (_user['plate'] ?? ''))
          'plate': _plate.text.trim(),
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
          child: Pressable(
            // Livreur indépendant : la photo de profil est le selfie de son dossier
            onTap: _uploading || api.isIndependent ? null : _takeSelfie,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Avatar(
                  _name.text.isEmpty ? '?' : _name.text,
                  radius: 46,
                  photo: _avatar,
                ),
                if (_uploading)
                  const Positioned.fill(
                    child: Center(child: CupertinoActivityIndicator()),
                  ),
                if (!api.isIndependent)
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: accent,
                        shape: BoxShape.circle,
                        border: Border.all(color: p.background, width: 3),
                      ),
                      child: const Icon(
                        PhosphorIconsFill.camera,
                        color: Colors.white,
                        size: 16,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          api.isIndependent
              ? 'Photo de profil : le selfie de votre dossier'
              : _avatar == null
              ? 'Ajouter un selfie'
              : 'Reprendre un selfie',
          textAlign: TextAlign.center,
          style: TextStyles.subheadline.copyWith(color: accent),
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
              icon: shop ? PhosphorIconsBold.bag : PhosphorIconsBold.user,
              onChanged: (_) => setState(() {}),
            ),
            PhoneField(controller: _phone, onChanged: (_) => setState(() {})),
          ],
        ),
        if (_editsPlate)
          InsetGroup(
            header: 'Engin',
            footer:
                'Affichée au client pendant la course pour qu’il vous reconnaisse.',
            children: [
              GroupField(
                controller: _plate,
                placeholder: 'Immatriculation (ex. AA 551 KR 01)',
                icon: PhosphorIconsBold.hash,
                capitalization: TextCapitalization.characters,
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
              icon: PhosphorIconsBold.lock,
              obscure: true,
              onChanged: (_) => setState(() {}),
            ),
            if (_needsPassword)
              GroupField(
                controller: _current,
                placeholder: 'Mot de passe actuel',
                icon: PhosphorIconsBold.shieldCheck,
                obscure: true,
              ),
          ],
        ),
      ],
    );
  }
}
