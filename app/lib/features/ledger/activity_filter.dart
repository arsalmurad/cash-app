import '../../data/rust/api/categories.dart';
import '../../data/rust/api/ledger.dart';

enum ActivityKindFilter { all, expense, income, transfer }

/// Search and filter over one device's activity feed — a pure, synchronous
/// function over data already loaded from the ledger, not a new bridge call:
/// with a personal ledger's scale, there is no reason to push this into Rust
/// and add a query surface for the ledger to keep byte-identical across.
class ActivityFilter {
  const ActivityFilter({
    this.query = '',
    this.kind = ActivityKindFilter.all,
    this.accountId,
  });

  final String query;
  final ActivityKindFilter kind;
  final String? accountId;

  bool get isActive =>
      query.trim().isNotEmpty || kind != ActivityKindFilter.all || accountId != null;

  ActivityFilter copyWith({
    String? query,
    ActivityKindFilter? kind,
    String? Function()? accountId,
  }) {
    return ActivityFilter(
      query: query ?? this.query,
      kind: kind ?? this.kind,
      accountId: accountId != null ? accountId() : this.accountId,
    );
  }

  List<TransactionView> applyToTransactions(
    List<TransactionView> transactions,
    List<CategoryView> categories,
  ) {
    if (kind == ActivityKindFilter.transfer) {
      return const [];
    }
    final normalized = query.trim().toLowerCase();
    return transactions.where((transaction) {
      if (accountId != null && transaction.accountId != accountId) {
        return false;
      }
      if (kind == ActivityKindFilter.expense && !transaction.isExpense) {
        return false;
      }
      if (kind == ActivityKindFilter.income && transaction.isExpense) {
        return false;
      }
      if (normalized.isEmpty) {
        return true;
      }
      final categoryName = _categoryName(categories, transaction.categoryId);
      return transaction.title.toLowerCase().contains(normalized) ||
          (categoryName?.toLowerCase().contains(normalized) ?? false);
    }).toList();
  }

  List<TransferView> applyToTransfers(List<TransferView> transfers) {
    if (kind == ActivityKindFilter.expense || kind == ActivityKindFilter.income) {
      return const [];
    }
    final normalized = query.trim().toLowerCase();
    return transfers.where((transfer) {
      if (accountId != null &&
          transfer.fromAccountId != accountId &&
          transfer.toAccountId != accountId) {
        return false;
      }
      if (normalized.isEmpty) {
        return true;
      }
      return transfer.title.toLowerCase().contains(normalized);
    }).toList();
  }

  String? _categoryName(List<CategoryView> categories, String? categoryId) {
    if (categoryId == null) {
      return null;
    }
    for (final category in categories) {
      if (category.id == categoryId) {
        return category.name;
      }
    }
    return null;
  }
}
