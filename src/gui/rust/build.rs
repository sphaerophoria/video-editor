use std::env;
use std::path::PathBuf;

fn main() {
    const GUI_HEADER: &str = "./../gui.h";
    println!("cargo:rerun-if-changed={}", GUI_HEADER);

    let bindings = bindgen::Builder::default()
        .header(GUI_HEADER)
        .generate()
        .expect("Unable to generate bindings");

    let out_path = PathBuf::from(env::var("OUT_DIR").unwrap());
    bindings
        .write_to_file(out_path.join("bindings.rs"))
        .expect("Couldn't write bindings!");
}
