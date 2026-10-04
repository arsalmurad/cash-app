// Make both Android 64-bit LOAD and RELRO boundaries explicitly 16 KB aligned.
// Keep this at the final cdylib link, without invalidating dependency RUSTFLAGS.
// https://developer.android.com/guide/practices/page-sizes
// https://doc.rust-lang.org/cargo/reference/build-scripts.html#rustc-link-arg-cdylib
pub(crate) fn android_cdylib_flags(os: &str, arch: &str) -> &'static [&'static str] {
    if os == "android" && matches!(arch, "aarch64" | "x86_64") {
        &[
            "-Wl,-z,max-page-size=16384",
            "-Wl,-z,common-page-size=16384",
        ]
    } else {
        &[]
    }
}

fn main() {
    println!("cargo::rerun-if-changed=build.rs");
    let os = std::env::var("CARGO_CFG_TARGET_OS").expect("Cargo target OS is required");
    let arch = std::env::var("CARGO_CFG_TARGET_ARCH").expect("Cargo target arch is required");
    for flag in android_cdylib_flags(&os, &arch) {
        println!("cargo::rustc-link-arg-cdylib={flag}");
    }
}
