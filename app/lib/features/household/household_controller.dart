import 'dart:math';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64Util;

import '../../data/rust/api/ledger.dart' show EntryKind;
import '../../data/rust/api/shared.dart';
import '../../data/storage/blob_store.dart';
import 'invite_codes.dart';
import 'household_journal.dart';
import 'relay_client.dart';

/// Runs the household layer: owns the network (the Rust core does no I/O),
/// persists the secret state after every change, and exposes the folded
/// view. The protocol itself (MLS, ordering, conflicts) lives in
/// `rust/sync`; this class only moves bytes between it and the relay, in
/// the same loop `cash_sync::Peer::sync` runs in Rust.
class HouseholdController extends ChangeNotifier {
  HouseholdController({
    BlobStore? stateStore,
    BlobStore? configStore,
    RelayClient Function(String url)? relayFactory,
    int Function()? clockMillis,
    String Function()? newMemberId,
  }) : _stateStore = stateStore ?? BlobStore('household'),
       _configStore = configStore ?? BlobStore('household-config'),
       _relayFactory = relayFactory ?? HttpRelayClient.new,
       _clockMillis =
           clockMillis ?? (() => DateTime.now().millisecondsSinceEpoch),
       _newMemberId = newMemberId ?? _randomId;

  static const reportingCurrency = 'USD';
  static const _accountId = 'household';
  static const _maxAttempts = 64;

  final BlobStore _stateStore;
  final BlobStore _configStore;
  final RelayClient Function(String url) _relayFactory;
  final int Function() _clockMillis;
  final String Function() _newMemberId;

  Household? _household;
  RelayClient? _relay;
  HouseholdOverview? overview;
  String? relayUrl;
  bool isBusy = false;
  String? errorMessage;
  bool isLoading = true;
  Future<void> _operationQueue = Future<void>.value();
  bool _writesDisabled = false;
  PendingInvitation? _pendingInvitation;
  String? lastInviteCode;
  String? _lastInviteRequest;
  bool get hasPendingInvitation => _pendingInvitation != null;
  static const _uncertainSaveMessage =
      'The household save could not be confirmed. Restart and check the '
      'household before retrying; the last change may already be saved.';

  bool get isMember => overview?.isMember ?? false;

  /// This device has an identity (and so can show a join request) but is
  /// not in a household yet.
  bool get hasIdentity => _household != null;

  static String _randomId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<void> initialize() => _enqueue(() async {
    try {
      _ensureWritable();
      final config = await _configStore.read();
      if (config != null && config.isNotEmpty) {
        relayUrl = String.fromCharCodes(config);
        _relay = _relayFactory(relayUrl!);
      }
      final saved = await _stateStore.read();
      if (saved != null) {
        await _loadSaved(saved);
        overview = await householdOverview(household: _household!);
      }
    } catch (error) {
      _disableWrites();
      errorMessage = error.toString();
    } finally {
      isLoading = false;
      notifyListeners();
    }
  });

  /// Sets the relay address (an `http(s)` URL). The relay sees only
  /// ciphertext, but it is still the one place everyone's traffic passes.
  Future<bool> setRelayUrl(String url) => _run(() async {
    final trimmed = url.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(trimmed);
    if (_pendingInvitation != null && trimmed != relayUrl) {
      throw const FormatException(
        'Finish the pending invitation before changing relays.',
      );
    }
    if (uri == null ||
        !(uri.scheme == 'https' || uri.scheme == 'http') ||
        uri.host.isEmpty) {
      throw const FormatException(
        'Enter a relay address starting with https://',
      );
    }
    await _saveConfig(trimmed);
    relayUrl = trimmed;
    _relay = _relayFactory(trimmed);
    errorMessage = null;
    notifyListeners();
  });

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final next = _operationQueue.then((_) => action());
    _operationQueue = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  void _ensureWritable() {
    if (_writesDisabled) throw const FormatException(_uncertainSaveMessage);
  }

  void _disableWrites() {
    _writesDisabled = true;
    _household = null;
  }

  Future<bool> _run(
    Future<void> Function() action, {
    bool allowRecovery = false,
  }) => _enqueue(() async {
    isBusy = true;
    errorMessage = null;
    notifyListeners();
    try {
      if (!allowRecovery) _ensureWritable();
      await action();
      return true;
    } on RelayUnavailable catch (error) {
      errorMessage = _writesDisabled ? _uncertainSaveMessage : error.toString();
      return false;
    } on FormatException catch (error) {
      errorMessage = _writesDisabled ? _uncertainSaveMessage : error.message;
      return false;
    } catch (error) {
      errorMessage = _writesDisabled ? _uncertainSaveMessage : error.toString();
      return false;
    } finally {
      isBusy = false;
      notifyListeners();
    }
  });

  RelayClient _requireRelay() {
    final relay = _relay;
    if (relay == null) {
      throw const FormatException('Set the relay address first.');
    }
    return relay;
  }

  Household _requireHousehold() {
    _ensureWritable();
    final household = _household;
    if (household == null) {
      throw const FormatException('There is no household on this device.');
    }
    return household;
  }

  Future<void> _refresh() async {
    overview = await householdOverview(household: _requireHousehold());
  }

  /// A failed save may already be durable. Drop the live handle rather than
  /// allowing later writes to publish or persist unconfirmed mutations.
  Future<void> _persist({String? relayOverride}) async {
    final bytes = await _savedBytes(relayOverride: relayOverride);
    try {
      await _stateStore.write(bytes);
    } catch (_) {
      _disableWrites();
      rethrow;
    }
  }

  Future<Uint8List> _savedBytes({String? relayOverride}) async =>
      HouseholdJournal(
        state: await householdExport(household: _requireHousehold()),
        relayUrl: relayOverride ?? relayUrl,
        pending: _pendingInvitation,
        lastCode: lastInviteCode,
        lastRequest: _lastInviteRequest,
      ).encode();

  Future<void> _loadSaved(Uint8List bytes) async {
    final saved = HouseholdJournal.decode(bytes);
    _household = await householdRestore(saved: saved.state);
    if (saved.relayUrl != null) {
      relayUrl = saved.relayUrl;
      _relay = _relayFactory(relayUrl!);
    }
    _pendingInvitation = saved.pending;
    lastInviteCode = saved.lastCode;
    _lastInviteRequest = saved.lastRequest;
  }

  Future<void> _saveConfig(String url) async {
    if (_household != null) {
      await _persist(relayOverride: url);
      return;
    }
    try {
      await _configStore.write(Uint8List.fromList(url.codeUnits));
    } catch (_) {
      _disableWrites();
      rethrow;
    }
  }

  Future<void> _ensureIdentity() async {
    if (_household != null) {
      return;
    }
    _household = await householdNew(
      memberId: _newMemberId(),
      reportingCurrencyCode: reportingCurrency,
    );
    await _persist();
  }

  String _newId(String prefix) {
    return '$prefix-${_randomId()}';
  }

  // --- Founding and joining ---------------------------------------------

  Future<bool> createHousehold() => _run(() async {
    _requireRelay();
    await _ensureIdentity();
    final household = _requireHousehold();
    await householdFound(household: household);
    await householdOpenAccount(
      household: household,
      accountId: _accountId,
      name: 'Household',
      currencyCode: reportingCurrency,
      wallClockMillis: PlatformInt64Util.from(_clockMillis()),
    );
    await _persist();
    await _refresh();
    await _sync();
  });

  /// The text a would-be member shows to whoever is inviting them. Creates
  /// this device's identity on first use; the key package's private half is
  /// saved before the code is returned, so it still works after a restart.
  Future<String?> prepareJoinRequest() async {
    String? code;
    final ok = await _run(() async {
      await _ensureIdentity();
      final household = _requireHousehold();
      final keyPackage = await householdKeyPackage(household: household);
      await _persist();
      code = encodeJoinRequest(keyPackage);
    });
    return ok ? code : null;
  }

  /// Adds the person behind [joinRequest] and returns the invite code to
  /// give them. Retries when another member's write wins the race.
  Future<String?> invite(String joinRequest) async {
    String? code;
    final ok = await _run(() async {
      final relay = _requireRelay();
      final household = _requireHousehold();
      final keyPackage = decodeJoinRequest(joinRequest);
      final request = base64.encode(keyPackage);
      if (_pendingInvitation != null) {
        if (_pendingInvitation!.request != request) {
          throw const FormatException(
            'Finish the pending invitation before adding someone else.',
          );
        }
        await _sync();
      }
      if (_lastInviteRequest == request) {
        code = lastInviteCode;
        return;
      }
      for (var attempt = 0; attempt < _maxAttempts; attempt += 1) {
        await _catchUp(relay, household);
        final staged = await householdBeginInvite(
          household: household,
          keyPackage: keyPackage,
        );
        _pendingInvitation = PendingInvitation(
          invite: HouseholdInvite(
            relayUrl: relayUrl!,
            group: _groupId(),
            mailbox: _randomId(),
          ),
          expectedTail: staged.commit.expectedTail.toInt(),
          commit: staged.commit.blob,
          welcome: staged.welcome,
          keyPackage: keyPackage,
          createdMillis: DateTime.now().millisecondsSinceEpoch,
        );
        lastInviteCode = null;
        _lastInviteRequest = null;
        // Both the pending MLS state and encrypted welcome precede network I/O.
        await _persist();
        await _refresh();
        await _sync();
        if (_lastInviteRequest == request) {
          code = lastInviteCode;
          return;
        }
      }
      throw const RelayUnavailable('the relay stayed busy; try again');
    });
    return ok ? code : null;
  }

  Future<String?> resumeInvitation() async {
    final pending = _pendingInvitation;
    if (pending == null) return lastInviteCode;
    return invite(encodeJoinRequest(pending.keyPackage));
  }

  Future<void> _finishInvitation(RelayClient relay) async {
    final pending = _pendingInvitation;
    if (pending == null) return;
    if (!pending.committed) {
      final entries = await relay.readAfter(
        pending.invite.group,
        pending.expectedTail,
      );
      if (entries.isEmpty) {
        throw const RelayUnavailable('invitation commit is still pending');
      }
      final first = entries.first;
      if (first.sequence != pending.expectedTail + 1) {
        throw const RelayUnavailable('invitation log slot is missing');
      }
      if (!listEquals(first.blob, pending.commit)) {
        _pendingInvitation = null; // Rust ingestion rejected this losing slot.
        await _persist();
        return;
      }
      pending.committed = true;
      await _persist();
    }
    if (pending.expired) {
      // Do not recreate a mailbox after its original seven-day retention.
      _pendingInvitation = null;
      await _persist();
      throw const FormatException(
        'The pending invite expired. Remove that member and request a fresh join code.',
      );
    }
    await relay.putMailbox(
      pending.invite.mailbox,
      pending.invite.group,
      pending.expectedTail + 1,
      pending.welcome,
    );
    lastInviteCode = pending.code;
    _lastInviteRequest = pending.request;
    _pendingInvitation = null;
    await _persist();
  }

  /// Joins using an invite code, after [prepareJoinRequest] produced the
  /// request it answers. Adopts the relay address the invite carries.
  Future<bool> acceptInvite(String inviteCode) => _run(() async {
    final invite = decodeInvite(inviteCode);
    final household = _requireHousehold();
    if (isMember) {
      throw const FormatException('This device is already in a household.');
    }
    final relay = _relayFactory(invite.relayUrl);
    final item = await relay.takeMailbox(invite.mailbox);
    if (item == null) {
      throw const FormatException(
        'That invite was already used or has expired.',
      );
    }
    if (item.group != invite.group) {
      throw const FormatException('That invite does not match its welcome.');
    }
    await householdJoin(
      household: household,
      groupId: item.group,
      welcome: item.welcome,
      joinedAfter: PlatformInt64Util.from(item.joinedAfter),
    );
    relayUrl = invite.relayUrl;
    _relay = relay;
    await _saveConfig(invite.relayUrl);
    await _persist();
    await _refresh();
    await _sync();
  });

  /// Forgets the household on this device (the others keep theirs). The
  /// identity is discarded too: rejoining needs a fresh invite.
  Future<void> forgetHousehold() async {
    await _run(() async {
      try {
        await _stateStore.delete();
      } catch (_) {
        _disableWrites();
        rethrow;
      }
      _household = null;
      overview = null;
      _pendingInvitation = null;
      lastInviteCode = null;
      _lastInviteRequest = null;
      _writesDisabled = false;
    }, allowRecovery: true);
  }

  // --- Recovery ---------------------------------------------------------

  /// A recovery phrase to write down, and this device's state sealed under
  /// it as text to store anywhere (a note, cloud drive, email to yourself).
  /// Without the phrase the backup is unreadable, and there is no server-side
  /// reset: lose both and the household is gone from this device.
  Future<({String phrase, String backup})?> createBackup() async {
    ({String phrase, String backup})? result;
    final ok = await _run(() async {
      final phrase = await recoveryGeneratePhrase();
      final sealed = await recoverySeal(
        phrase: phrase,
        plaintext: await _savedBytes(),
      );
      result = (phrase: phrase, backup: encodeBackup(sealed));
    });
    return ok ? result : null;
  }

  /// Restores a household from a backup and its phrase, for a replacement
  /// device. The old device must be treated as gone: two devices with the
  /// same member identity would fork it.
  Future<bool> restoreBackup(String phrase, String backupCode) =>
      _run(() async {
        if (isMember) {
          throw const FormatException('This device is already in a household.');
        }
        final plaintext = await recoveryOpen(
          phrase: phrase,
          sealed: decodeBackup(backupCode),
        );
        await _loadSaved(plaintext);
        _writesDisabled = false;
        await _persist();
        await _refresh();
        if (_relay == null && relayUrl != null) {
          _relay = _relayFactory(relayUrl!);
        }
        if (_relay != null) {
          await _sync();
        }
      }, allowRecovery: true);

  // --- Shared expenses --------------------------------------------------

  Future<bool> addExpense({
    required String title,
    required String amount,
    EntryKind kind = EntryKind.expense,
  }) => _write(
    () => householdRecordTransaction(
      household: _requireHousehold(),
      transactionId: _newId('shared'),
      accountId: _accountId,
      kind: kind,
      amount: amount,
      currencyCode: reportingCurrency,
      fxNumerator: PlatformInt64Util.from(1),
      fxDenominator: PlatformInt64Util.from(1),
      title: title.trim(),
      wallClockMillis: PlatformInt64Util.from(_clockMillis()),
    ),
  );

  Future<bool> adjustAmount(String transactionId, String amount) => _write(
    () => householdAdjustAmount(
      household: _requireHousehold(),
      transactionId: transactionId,
      amount: amount,
      currencyCode: reportingCurrency,
      fxNumerator: PlatformInt64Util.from(1),
      fxDenominator: PlatformInt64Util.from(1),
      wallClockMillis: PlatformInt64Util.from(_clockMillis()),
    ),
  );

  Future<bool> voidTransaction(String transactionId) => _write(
    () => householdVoidTransaction(
      household: _requireHousehold(),
      transactionId: transactionId,
      wallClockMillis: PlatformInt64Util.from(_clockMillis()),
    ),
  );

  /// Applies a local write, saves it, then tries to send it. A failed send
  /// is reported but the write is kept and retried by the next sync.
  Future<bool> _write(Future<void> Function() write) => _run(() async {
    await write();
    await _persist();
    await _refresh();
    await _sync();
  });

  // --- Sync -------------------------------------------------------------

  Future<bool> syncNow() => _run(_sync);

  String _groupId() {
    final group = overview?.groupId;
    if (group == null) {
      throw const FormatException('There is no household on this device.');
    }
    return group;
  }

  Future<void> _catchUp(RelayClient relay, Household household) async {
    final overview = await householdOverview(household: household);
    final entries = await relay.readAfter(_groupId(), overview.cursor.toInt());
    if (entries.isNotEmpty) {
      await householdIngest(
        household: household,
        entries: [
          for (final entry in entries)
            RelayEntry(
              sequence: PlatformInt64Util.from(entry.sequence),
              blob: entry.blob,
            ),
        ],
      );
    }
  }

  Future<void> _sync() async {
    final relay = _requireRelay();
    final household = _requireHousehold();
    if (!isMember) {
      return;
    }
    try {
      var conflicts = 0;
      while (true) {
        await _catchUp(relay, household);
        final next = await householdNextOutgoing(household: household);
        if (next == null) {
          break;
        }
        // Encryption advances the sender ratchet: save it before any bytes
        // reach the relay, including an append whose response may be lost.
        await _persist();
        try {
          final sequence = await relay.append(
            _groupId(),
            next.expectedTail.toInt(),
            next.blob,
          );
          await householdOutgoingAccepted(
            household: household,
            sequence: PlatformInt64Util.from(sequence),
          );
        } on RelayConflict {
          conflicts += 1;
          if (conflicts >= _maxAttempts) {
            throw const RelayUnavailable('the relay stayed busy');
          }
        }
      }
      await _finishInvitation(relay);
    } finally {
      // Whatever happened, keep what was learned and what is still queued.
      if (!_writesDisabled) {
        await _persist();
        await _refresh();
      }
    }
  }

  // --- Members ----------------------------------------------------------

  Future<bool> removeMember(String memberId) => _run(() async {
    final relay = _requireRelay();
    final household = _requireHousehold();
    for (var attempt = 0; attempt < _maxAttempts; attempt += 1) {
      await _catchUp(relay, household);
      await householdBeginRemoval(household: household, memberId: memberId);
      // The Rust journal retains this exact commit across a lost response.
      await _persist();
      await _refresh();
      await _sync();
      if (!overview!.memberIds.contains(memberId)) {
        lastInviteCode = null;
        _lastInviteRequest = null;
        await _persist();
        return;
      }
    }
    throw const RelayUnavailable('the relay stayed busy; try again');
  });

  Future<String?> safetyNumberWith(String memberId) => _enqueue(() async {
    try {
      return await householdSafetyNumber(
        household: _requireHousehold(),
        memberId: memberId,
      );
    } catch (error) {
      errorMessage = error.toString();
      notifyListeners();
      return null;
    }
  });
}
