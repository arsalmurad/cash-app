import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('adaptive Cupertino controls have their bundled icon font', () async {
    expect(CupertinoIcons.clear_thick_circled.fontFamily, 'CupertinoIcons');
    expect(CupertinoIcons.clear_thick_circled.fontPackage, 'cupertino_icons');
    final font = await rootBundle.load(
      'packages/cupertino_icons/assets/CupertinoIcons.ttf',
    );
    expect(font.lengthInBytes, greaterThan(1000));
  });
}
