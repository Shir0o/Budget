import 'package:budget_core/budget_core.dart';
import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets.dart';

/// Possible transfers (issue 3): two bank lines in different accounts that
/// look like one transfer or card payment. Linking turns them into one
/// transfer; nothing links until a person taps (ADR 0003). A pair that isn't
/// a transfer goes away once either line is reviewed as usual.
class PossibleTransferScreen extends StatefulWidget {
  const PossibleTransferScreen({super.key, required this.engine});

  final BudgetEngine engine;

  @override
  State<PossibleTransferScreen> createState() => _PossibleTransferScreenState();
}

class _PossibleTransferScreenState extends State<PossibleTransferScreen> {
  BudgetState get _state => widget.engine.state;

  void _link(TransferProposal proposal) {
    widget.engine.execute(
      LinkTransfer(
        outflowId: proposal.outflow.id,
        inflowId: proposal.inflow.id,
      ),
    );
    if (!mounted) return;
    // The last link closes the screen.
    if (_state.proposedTransfers.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final proposals = _state.proposedTransfers;
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 16, 16, 4),
              child: Row(
                spacing: 4,
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: 'Back',
                    constraints: const BoxConstraints.tightFor(
                      width: 44,
                      height: 44,
                    ),
                    icon: const Icon(Icons.chevron_left, color: Palette.ink),
                  ),
                  const Expanded(
                    child: Text(
                      'Possible transfers',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (proposals.length > 1)
                    Text(
                      '${proposals.length} waiting',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Palette.muted,
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  if (proposals.isEmpty)
                    const CardBox(
                      padding: EdgeInsets.all(18),
                      child: Text(
                        'No bank lines look like a transfer.',
                        style: TextStyle(fontSize: 14, color: Palette.muted),
                      ),
                    )
                  else
                    for (final (i, proposal) in proposals.indexed) ...[
                      if (i > 0) const SizedBox(height: 12),
                      CardBox(
                        key: const ValueKey('possible-transfer'),
                        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          spacing: 14,
                          children: [
                            TransferSide(
                              state: _state,
                              label: 'Left',
                              transaction: proposal.outflow,
                            ),
                            const Divider(height: 1, color: Palette.divider),
                            TransferSide(
                              state: _state,
                              label: 'Arrived',
                              transaction: proposal.inflow,
                            ),
                            FilledButton(
                              key: const ValueKey('link-transfer'),
                              onPressed: () => _link(proposal),
                              child: const Text('Link as one transfer'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  if (proposals.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Hint(
                      'Nothing changes until you link. A linked pair leaves '
                      'Review, and paying a card spends its Card Payment '
                      'Category. Not a transfer? Review each line as usual '
                      'and it goes away.',
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One side of a possible transfer: its account, payee, date and amount.
class TransferSide extends StatelessWidget {
  const TransferSide({
    super.key,
    required this.state,
    required this.label,
    required this.transaction,
  });

  final BudgetState state;
  final String label;
  final Transaction transaction;

  @override
  Widget build(BuildContext context) {
    final account = state.account(transaction.accountId)?.name ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 2,
      children: [
        Text(
          '$label · $account',
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Palette.muted,
          ),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 2,
                children: [
                  Text(
                    transaction.payee.isEmpty ? 'No payee' : transaction.payee,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    formatDay(transaction.date),
                    style: const TextStyle(fontSize: 13, color: Palette.muted),
                  ),
                ],
              ),
            ),
            Text(
              formatSigned(transaction.amount),
              style: amountStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ],
    );
  }
}

/// A row in Review that opens [PossibleTransferScreen].
class PossibleTransfersLink extends StatelessWidget {
  const PossibleTransfersLink({
    super.key,
    required this.count,
    required this.onTap,
  });

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => CardBox(
    padding: EdgeInsets.zero,
    child: Semantics(
      button: true,
      child: InkWell(
        key: const ValueKey('review-possible-transfers'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            spacing: 12,
            children: [
              const Icon(Icons.swap_horiz, size: 20, color: Palette.bankText),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    Text(
                      count == 1
                          ? '1 possible transfer'
                          : '$count possible transfers',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const Text(
                      'Two bank lines look like one transfer',
                      style: TextStyle(fontSize: 12, color: Palette.muted),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, size: 18, color: Palette.muted),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Lets a person pick the other side of a transfer for [transaction] and
/// links the two (issue 3). Returns true when they linked.
Future<bool> pickTransferPartner(
  BuildContext context,
  BudgetEngine engine,
  Transaction transaction,
) async {
  final state = engine.state;
  final partners = state.transferPartnersFor(transaction).take(20).toList();
  final picked = await showModalBottomSheet<Transaction>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Palette.card,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          const Text(
            'Link as transfer',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          const Hint('Pick the other side, in another account.'),
          const SizedBox(height: 8),
          if (partners.isEmpty)
            const Text(
              'No line in another account has the opposite amount.',
              style: TextStyle(fontSize: 14, color: Palette.muted),
            ),
          for (final partner in partners)
            InkWell(
              key: ValueKey('transfer-partner-${partner.id}'),
              onTap: () => Navigator.of(context).pop(partner),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: TransferSide(
                  state: state,
                  label: partner.amount.isNegative ? 'Left' : 'Arrived',
                  transaction: partner,
                ),
              ),
            ),
        ],
      ),
    ),
  );
  if (picked == null) return false;
  final outflow = transaction.amount.isNegative ? transaction : picked;
  final inflow = transaction.amount.isNegative ? picked : transaction;
  final result = engine.execute(
    LinkTransfer(outflowId: outflow.id, inflowId: inflow.id),
  );
  return result is Accepted;
}
