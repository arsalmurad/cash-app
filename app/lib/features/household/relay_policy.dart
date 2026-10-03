/// Public relay permissions only. This is not an MLS roster certificate.
class RelayAuthorizedDevice {
  RelayAuthorizedDevice._(this.key, List<String> operations)
    : operations = List.unmodifiable(operations);
  final String key;
  final List<String> operations;
}

class RelayAuthorizationPolicy {
  RelayAuthorizationPolicy._(
    this.origin,
    this.group,
    this.epoch,
    List<RelayAuthorizedDevice> devices,
  ) : devices = List.unmodifiable(devices);
  static const maximumInteger = 9007199254740991;
  static const _operations = ['append', 'membership', 'read'];
  final String origin;
  final String group;
  final int epoch;
  final List<RelayAuthorizedDevice> devices;

  static Never _invalid() =>
      throw const FormatException('Invalid relay authorization policy.');
  static Map<String, dynamic> _object(Object? value, Set<String> fields) {
    if (value is! Map ||
        value.length != fields.length ||
        !value.keys.every(fields.contains)) {
      _invalid();
    }
    return Map<String, dynamic>.from(value);
  }

  factory RelayAuthorizationPolicy.fromJson(
    Object? value, {
    required String origin,
    required String group,
  }) {
    final uri = Uri.tryParse(origin);
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        !uri.hasAuthority ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.hasQuery ||
        uri.origin != origin ||
        (uri.scheme == 'http' &&
            !['127.0.0.1', 'localhost', '::1', '[::1]'].contains(uri.host)) ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(group)) {
      _invalid();
    }
    final raw = _object(value, {'version', 'epoch', 'scope', 'devices'});
    final scope = _object(raw['scope'], {'origin', 'kind', 'id'});
    if (raw['version'] is! int ||
        raw['version'] != 2 ||
        raw['epoch'] is! int ||
        raw['epoch'] < 0 ||
        raw['epoch'] > maximumInteger ||
        scope['origin'] != origin ||
        scope['kind'] != 'g' ||
        scope['id'] != group) {
      _invalid();
    }
    final rows = raw['devices'];
    if (rows is! List || rows.isEmpty || rows.length > 64) _invalid();
    final devices = <RelayAuthorizedDevice>[];
    var previous = '';
    for (final row in rows) {
      final device = _object(row, {'key', 'operations'});
      final key = device['key'];
      final operations = device['operations'];
      if (key is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(key) ||
          key.compareTo(previous) <= 0 ||
          operations is! List ||
          operations.isEmpty ||
          operations.length > 3) {
        _invalid();
      }
      final grants = <String>[];
      for (final operation in operations) {
        if (operation is! String ||
            !_operations.contains(operation) ||
            (grants.isNotEmpty && operation.compareTo(grants.last) <= 0)) {
          _invalid();
        }
        grants.add(operation);
      }
      devices.add(RelayAuthorizedDevice._(key, grants));
      previous = key;
    }
    if (!devices.any((device) => device.operations.contains('membership'))) {
      _invalid();
    }
    return RelayAuthorizationPolicy._(
      origin,
      group,
      raw['epoch'] as int,
      devices,
    );
  }

  /// Survivors retain their grants. New MLS members receive the app's standard
  /// household capabilities; the server still requires the current sponsor.
  RelayAuthorizationPolicy nextForRosterKeys(List<String> keys) {
    if (epoch >= maximumInteger ||
        keys.isEmpty ||
        keys.length > 64 ||
        keys.toSet().length != keys.length) {
      _invalid();
    }
    final sorted = [...keys]..sort();
    final existing = {
      for (final device in devices) device.key: device.operations,
    };
    return RelayAuthorizationPolicy.fromJson(
      {
        'version': 2,
        'epoch': epoch + 1,
        'scope': {'origin': origin, 'kind': 'g', 'id': group},
        'devices': [
          for (final key in sorted)
            {'key': key, 'operations': existing[key] ?? _operations},
        ],
      },
      origin: origin,
      group: group,
    );
  }

  Map<String, Object?> toJson() => {
    'version': 2,
    'epoch': epoch,
    'scope': {'origin': origin, 'kind': 'g', 'id': group},
    'devices': [
      for (final device in devices)
        {
          'key': device.key,
          'operations': [...device.operations],
        },
    ],
  };
}
