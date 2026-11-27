import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../api.dart';
import '../countries.dart';
import '../main.dart';
import '../realtime.dart';
import 'widgets.dart';

const _status = {
  'PAID': 'À confirmer',
  'CONFIRMED': 'Reçue',
  'DISPUTED': 'Contestée',
};
const _advStatus = {
  'PENDING': 'En attente',
  'GIVEN': 'Versée · retenue sur la prochaine paie',
  'REJECTED': 'Refusée',
  'DEDUCTED': 'Retenue sur la paie',
};

/// Livreur d'une entreprise : estimation de la période, fiches de paie (confirmer / contester), avances
class PayrollScreen extends StatefulWidget {
  /// Données déjà chargées (tests)
  final Map<String, dynamic>? initial;
  const PayrollScreen({super.key, this.initial});
  @override
  State<PayrollScreen> createState() => _PayrollScreenState();
}

class _PayrollScreenState extends State<PayrollScreen> {
  final api = Api.instance;
  late Map<String, dynamic>? _d = widget.initial;
  bool _busy = false;
  void Function()? _unlisten;

  @override
  void initState() {
    super.initState();
    if (_d == null) _load();
    if (api.token == null) return;
    final s = Realtime.instance.socket;
    void h(dynamic _) => _load();
    s.on('payroll:changed', h);
    _unlisten = () => s.off('payroll:changed', h);
  }

  @override
  void dispose() {
    _unlisten?.call();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await api.myPayroll();
      if (mounted) setState(() => _d = d);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _act(
    Future<Map<String, dynamic>> Function() f,
    String done,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final d = await f();
      if (!mounted) return;
      hapticSuccess();
      setState(() => _d = d);
      showInfo(context, done);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _requestAdvance() async {
    final amount = await prompt(
      context,
      'Demander une avance',
      message:
          'Montant souhaité. Une fois versée, l’avance est retenue sur votre prochaine paie.',
      placeholder: 'Montant',
      keyboard: TextInputType.number,
      ok: 'Continuer',
    );
    final n = int.tryParse((amount ?? '').replaceAll(RegExp(r'\D'), ''));
    if (n == null || n <= 0 || !mounted) return;
    final reason = await prompt(
      context,
      'Motif (facultatif)',
      placeholder: 'Ex. : carburant, réparation',
      ok: 'Envoyer la demande',
    );
    if (reason == null) return;
    await _act(
      () => api.requestAdvance(
        n,
        reason: reason.trim().isEmpty ? null : reason.trim(),
      ),
      'Demande envoyée à votre entreprise',
    );
  }

  Future<void> _openSlip(Map s) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Palette.of(context).background,
      shape: const RoundedSuperellipseBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _SlipSheet(slip: s),
    );
    if (!mounted || action == null) return;
    if (action == 'confirm') {
      await _act(() => api.confirmPayslip(s['id']), 'Réception confirmée');
    } else {
      final note = await prompt(
        context,
        'Contester la paie',
        message: 'Expliquez ce qui ne va pas : votre entreprise est prévenue.',
        placeholder: 'Ex. : il manque une course',
        ok: 'Contester',
      );
      if (note == null || note.trim().isEmpty) return;
      await _act(
        () => api.disputePayslip(s['id'], note.trim()),
        'Contestation envoyée',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final d = _d;
    return LargeTitlePage(
      title: 'Ma paye',
      onRefresh: _load,
      children: [
        if (d == null)
          const Padding(
            padding: EdgeInsets.all(32),
            child: CupertinoActivityIndicator(),
          )
        else if (d['enabled'] != true)
          InsetGroup(
            footer:
                'Votre entreprise ne calcule pas encore la paie dans VITE. Vos encaissements et versements restent dans « Gains ».',
            children: [
              GroupRow(
                leading: IconBadge(
                  PhosphorIconsFill.wallet,
                  color: p.secondaryLabel,
                ),
                title: 'Paye non activée',
              ),
            ],
          )
        else ...[
          _current(p, d['current'] as Map),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 22),
            child: TintedButton(
              'Demander une avance',
              icon: PhosphorIconsBold.handCoins,
              onPressed: _busy ? null : _requestAdvance,
            ),
          ),
          if (((d['payslips'] as List?) ?? []).isNotEmpty)
            InsetGroup(
              header: 'Mes fiches de paie',
              children: [
                for (final s in (d['payslips'] as List).cast<Map>())
                  GroupRow(
                    leading: IconBadge(
                      s['status'] == 'CONFIRMED'
                          ? PhosphorIconsFill.sealCheck
                          : s['status'] == 'DISPUTED'
                          ? PhosphorIconsFill.warningCircle
                          : PhosphorIconsFill.envelopeSimple,
                      color: s['status'] == 'CONFIRMED'
                          ? p.green
                          : s['status'] == 'DISPUTED'
                          ? p.red
                          : accent,
                    ),
                    title: s['label'] ?? '',
                    subtitle: _status[s['status']],
                    value: formatMoney(s['net'] ?? 0),
                    chevron: true,
                    onTap: () => _openSlip(s),
                  ),
              ],
            ),
          if (((d['advances'] as List?) ?? []).isNotEmpty)
            InsetGroup(
              header: 'Mes avances',
              children: [
                for (final a in (d['advances'] as List).cast<Map>())
                  GroupRow(
                    leading: Icon(
                      PhosphorIconsBold.handCoins,
                      color: p.secondaryLabel,
                      size: 20,
                    ),
                    title: formatMoney(a['amount'] ?? 0),
                    subtitle: [
                      _advStatus[a['status']] ?? '',
                      if ((a['note'] ?? '').toString().isNotEmpty)
                        '« ${a['note']} »',
                    ].join(' · '),
                  ),
              ],
            ),
        ],
      ],
    );
  }

  /// Période en cours : estimation (évolue avec les courses)
  Widget _current(Palette p, Map c) {
    final lines = ((c['lines'] as List?) ?? []).cast<Map>();
    return InsetGroup(
      header: 'En cours · ${c['label'] ?? ''}',
      footer:
          'Estimation : elle évolue avec vos courses. Les espèces encaissées et pas encore versées seront déduites au moment de la paie.',
      children: [
        GroupRow(
          leading: const IconBadge(PhosphorIconsFill.wallet, color: accent),
          title: 'Estimation',
          subtitle:
              '${c['stops'] ?? 0} colis livré(s) · ${c['deliveries'] ?? 0} course(s)',
          value: formatMoney(c['gross'] ?? 0),
        ),
        for (final l in lines)
          GroupRow(
            title: l['label'] ?? '',
            value:
                '${(l['amount'] ?? 0) > 0 ? '+' : ''}${formatMoney(l['amount'] ?? 0)}',
          ),
      ],
    );
  }
}

class _SlipSheet extends StatelessWidget {
  final Map slip;
  const _SlipSheet({required this.slip});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final lines = ((slip['lines'] as List?) ?? []).cast<Map>();
    final paid = slip['status'] == 'PAID';
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            const Center(child: Grabber()),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text(
                slip['label'] ?? '',
                style: TextStyles.title2.copyWith(color: p.label),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                '${slip['deliveries'] ?? 0} course(s) · ${slip['stops'] ?? 0} colis livré(s)',
                style: TextStyles.subheadline.copyWith(color: p.secondaryLabel),
              ),
            ),
            InsetGroup(
              children: [
                for (final l in lines)
                  GroupRow(
                    title: l['label'] ?? '',
                    value:
                        '${(l['amount'] ?? 0) > 0 ? '+' : ''}${formatMoney(l['amount'] ?? 0)}',
                  ),
                GroupRow(
                  leading: const IconBadge(
                    PhosphorIconsFill.wallet,
                    color: accent,
                  ),
                  title: 'Net payé',
                  subtitle: [
                    if (slip['method'] == 'MOBILE_MONEY')
                      'Mobile Money'
                    else if (slip['method'] == 'CASH')
                      'Espèces',
                    if ((slip['reference'] ?? '').toString().isNotEmpty)
                      'réf. ${slip['reference']}',
                  ].join(' · '),
                  value: formatMoney(slip['net'] ?? 0),
                ),
              ],
            ),
            if (slip['status'] == 'DISPUTED' &&
                (slip['disputeNote'] ?? '').toString().isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  'Contestée : « ${slip['disputeNote']} »',
                  style: TextStyles.footnote.copyWith(color: p.secondaryLabel),
                ),
              ),
            if (paid)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: TintedButton(
                        'Contester',
                        onPressed: () => Navigator.pop(context, 'dispute'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: primaryButton,
                          foregroundColor: onPrimaryButton,
                        ),
                        onPressed: () => Navigator.pop(context, 'confirm'),
                        child: const Text('J’ai bien reçu'),
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
}
