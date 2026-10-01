import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final name in ['NotoSansArabic', 'NotoEmoji']) {
    test('$name is a bundled, loadable TrueType font', () async {
      final bytes = await rootBundle.load('assets/fonts/$name.ttf');
      expect(bytes.buffer.asUint8List(bytes.offsetInBytes, 4), [0, 1, 0, 0]);
      final loader = FontLoader(name)..addFont(Future.value(bytes));
      await loader.load();
    });
  }
}
