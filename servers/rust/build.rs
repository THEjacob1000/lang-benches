use std::{env, fs, process::Command};

fn main() {
    println!("cargo:rerun-if-changed=Cargo.lock");
    println!("cargo:rerun-if-changed=rust-toolchain.toml");
    println!("cargo:rerun-if-env-changed=RUSTC");

    let compiler = env::var_os("RUSTC").expect("Cargo must supply RUSTC");
    let output = Command::new(compiler)
        .arg("--version")
        .output()
        .expect("failed to query the build compiler");
    assert!(
        output.status.success(),
        "build compiler version query failed"
    );
    let compiler_version =
        String::from_utf8(output.stdout).expect("compiler version must be UTF-8");
    let rust_version = compiler_version
        .split_whitespace()
        .nth(1)
        .expect("compiler version output must include its version");
    println!("cargo:rustc-env=RUST_VERSION={rust_version}");

    // Cargo generates these package records with quoted name and version fields.
    let lockfile = fs::read_to_string("Cargo.lock").expect("the committed Cargo.lock must exist");
    let mut axum_packages = lockfile
        .split("\n[[package]]")
        .filter(|package| package.lines().any(|line| line.trim() == "name = \"axum\""));
    let axum_package = axum_packages.next().expect("Cargo.lock must contain axum");
    assert!(
        axum_packages.next().is_none(),
        "multiple axum versions in Cargo.lock require selecting the direct dependency"
    );
    let axum_version = axum_package
        .lines()
        .find_map(|line| line.trim().strip_prefix("version = \"")?.strip_suffix('"'))
        .expect("the axum package must contain a version");
    println!("cargo:rustc-env=AXUM_VERSION={axum_version}");
}
