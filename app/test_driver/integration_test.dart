import 'package:integration_test/integration_test_driver.dart';

// `writeResponseOnFailure: true`: the `-d web-server` device has no browser
// console access at all (flutter drive prints "requires the Dart Debug
// Chrome extension for debugging" for it), so `print()` inside a failing
// test never reaches CI output, and the driver's own failure-detail
// reporting has independently come back empty on every build mode tried.
// `reportData` is a separate channel that does get written to disk
// (`build/integration_response_data.json`) even on failure, so the test
// attaches the real exception there instead.
Future<void> main() => integrationDriver(writeResponseOnFailure: true);
