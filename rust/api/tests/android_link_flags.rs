#[allow(dead_code)]
#[path = "../build.rs"]
mod build_script;

#[test]
fn android_64_bit_cdylibs_set_both_page_boundaries() {
    for arch in ["aarch64", "x86_64"] {
        assert_eq!(
            build_script::android_cdylib_flags("android", arch),
            &[
                "-Wl,-z,max-page-size=16384",
                "-Wl,-z,common-page-size=16384"
            ]
        );
    }
}

#[test]
fn no_android_flags_leak_to_other_platforms() {
    for (os, arch) in [
        ("windows", "x86_64"),
        ("ios", "aarch64"),
        ("macos", "aarch64"),
        ("unknown", "wasm32"),
        ("linux", "aarch64"),
    ] {
        assert!(build_script::android_cdylib_flags(os, arch).is_empty());
    }
}

#[test]
fn leaves_32_bit_android_unchanged() {
    for arch in ["arm", "x86"] {
        assert!(build_script::android_cdylib_flags("android", arch).is_empty());
    }
}
