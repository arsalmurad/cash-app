# Borrowed material

| What | Source | Destination |
| --- | --- | --- |
| MLS credential, key-package, Welcome, and commit sequence, adapted for the spike | [OpenMLS quickstart](https://docs.rs/openmls/0.9.0/src/openmls/lib.rs.html) | `mls_spike/rust/src/crypto.rs` |
| Generated Cargokit native-build scaffold, renamed and pointed at the app bridge crate | [flutter_rust_bridge 2.13.0 template](https://github.com/fzyzcjy/flutter_rust_bridge) | `app/rust_builder` |
| `civil_from_days`/`days_from_civil` integer proleptic-Gregorian calendar algorithm (public domain), used to find a budget period's calendar-aligned start and a recurring rule's next occurrence without a date/chrono dependency | [Howard Hinnant, "chrono-Compatible Low-Level Date Algorithms"](https://howardhinnant.github.io/date_algorithms.html) | `rust/core/src/calendar.rs` |
| Noto Sans Arabic and Noto Emoji variable font assets, unchanged, with upstream notices and pinned hashes | [Google Fonts revision 9710da1](https://github.com/google/fonts/tree/9710da1eacb3be272583c3224dcb70f9da6eadbb/ofl) | `app/assets/fonts` |
