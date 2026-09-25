import 'package:flutter_test/flutter_test.dart';
import 'package:mls_spike/src/rust/api/mls.dart';
import 'package:mls_spike/src/rust/frb_generated.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(RustLib.init);

  test('removed member cannot decrypt the next epoch in a browser', () async {
    final spike = await createGroup();
    addTearDown(spike.dispose);

    expect(await addMember(spike: spike), isTrue);
    expect(await removeMemberAndVerify(spike: spike), isTrue);
  });
}
