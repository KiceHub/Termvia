#!/usr/bin/env python3
"""Copy the linked Rust dependencies' license notices into the app bundle."""
import json
from pathlib import Path
from shutil import copyfile
import subprocess
import sys


def dependencies():
    cargo = ["--manifest-path", "RustHelpers/Cargo.toml", "--locked"]
    target = "aarch64-apple-darwin"
    # Metadata describes the full lockfile. The tree supplies the features
    # and build dependencies selected for this particular target.
    tree = subprocess.check_output([
        "cargo", "tree", *cargo, "--workspace", "--target", target,
        "--edges", "normal,build", "--prefix", "none", "--format", "{p}",
    ], text=True)
    selected = {tuple(line.split()[:2]) for line in tree.splitlines() if line}
    metadata = json.loads(subprocess.check_output([
        "cargo", "metadata", *cargo, "--format-version", "1", "--filter-platform", target,
    ]))
    return sorted(
        (package for package in metadata["packages"]
         if package["source"] and (package["name"], "v" + package["version"]) in selected),
        key=lambda package: (package["name"], package["version"]),
    )


def licenses(package):
    root = Path(package["manifest_path"]).parent
    files = {path for path in root.iterdir()
             if path.is_file() and path.name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "NOTICE"))}
    if package["license_file"]:
        files.add(root / package["license_file"])
    if not files and (package["name"], package["version"]) == ("boringtun", "0.7.1"):
        # The crate omits the repository's BSD license.
        files.add(Path("RustHelpers/licenses/boringtun-0.7.1.txt"))
    if not files:
        raise RuntimeError(f'No license text found for {package["name"]} {package["version"]}')
    return sorted(files)


def main(destination):
    notices = []
    for package in dependencies():
        name, version = package["name"], package["version"]
        folder = destination / f"{name}-{version}"
        folder.mkdir(parents=True)
        for path in licenses(package):
            copyfile(path, folder / path.name)
        notices.append(f'{name} {version}\t{package["license"] or package["license_file"]}\n')
    destination.joinpath("Dependencies.txt").write_text("".join(notices), encoding="utf-8")

    sysroot = Path(subprocess.check_output(["rustc", "--print", "sysroot"], text=True).strip())
    rust_docs = sysroot / "share/doc/rust"
    copyfile(rust_docs / "COPYRIGHT-library.html", destination / "Rust-COPYRIGHT-library.html")
    rust_licenses = destination / "Rust"
    rust_licenses.mkdir()
    for path in sorted((rust_docs / "licenses").iterdir()):
        if path.is_file():
            copyfile(path, rust_licenses / path.name)


if __name__ == "__main__":
    try:
        main(Path(sys.argv[1]))
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
