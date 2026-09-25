import 'package:flutter_test/flutter_test.dart';
import 'package:mls_spike/src/rust/api/mls.dart';
import 'package:mls_spike/src/rust/frb_generated.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());
  testWidgets('removed member cannot decrypt next epoch', (tester) async {
    final spike = await createGroup();
    expect(await addMember(spike: spike), isTrue);
    expect(await removeMemberAndVerify(spike: spike), isTrue);
    spike.dispose();
  });
}
