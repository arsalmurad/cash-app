Pod::Spec.new do |s|
  s.name = 'rust_lib_cash_app'
  s.version = '0.0.1'
  s.summary = 'Native Rust ledger core for Private Ledger.'
  s.description = 'Builds the local-first Rust ledger through flutter_rust_bridge.'
  s.homepage = 'https://github.com/arsalmurad/cash-app'
  s.license = { :file => '../LICENSE' }
  s.author = { 'Private Ledger' => 'private@example.invalid' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.14'
  s.swift_version = '5.0'
  s.script_phase = {
    :name => 'Build Rust library',
    :script => 'sh "$PODS_TARGET_SRCROOT/../cargokit/build_pod.sh" ../../../rust/api rust_lib_cash_app',
    :execution_position => :before_compile,
    :input_files => ['${BUILT_PRODUCTS_DIR}/cargokit_phony'],
    :output_files => ["${BUILT_PRODUCTS_DIR}/librust_lib_cash_app.a"],
  }
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'OTHER_LDFLAGS' => '-force_load ${BUILT_PRODUCTS_DIR}/librust_lib_cash_app.a',
  }
end
