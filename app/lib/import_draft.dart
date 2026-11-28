import 'package:budget_core/budget_core.dart';
import 'package:budget_migration/budget_migration.dart';

/// The Actual import wizard's state while the person moves between its
/// screens. Nothing is written until Map tags commits, so backing up a step
/// keeps every decision.
final class ImportDraft {
  ImportDraft({
    required this.export,
    required this.tags,
    required this.today,
    this.newBudgetName,
  });

  final ActualExport export;

  /// The Business Tag decisions, in the order Map tags lists them.
  final List<TagMapping> tags;
  final CivilDate today;

  /// Set when the import starts a new budget from the first-run screen: the
  /// budget is created with this name in the same commit as the import, so
  /// backing out of the wizard writes nothing.
  final String? newBudgetName;

  ImportPlan plan() =>
      buildImportPlan(export: export, tagMappings: tags, today: today);
}
