#![cfg_attr(windows, windows_subsystem = "windows")]
#[cfg(windows)]
mod win;
#[cfg(windows)]
fn main() {
    win::main();
}
#[cfg(not(windows))]
fn main() {
    eprintln!("OpenCU Windows engine requires Windows. Platform-independent tests: cargo test");
    std::process::exit(1);
}
