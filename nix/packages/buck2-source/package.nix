# SPDX-FileCopyrightText: 2026 Austin Seipp
# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

# Nix expression to build Buck2 from source.
# Based, in part, on https://github.com/thoughtpolice/buck2-nix/blob/c602d0f44f03310a89f209a322bb122b0d3c557a/buck/nix/buck2/default.nix
#
# To update Buck2:
# - change the `git_rev` and `src.hash` attributes below.
# - copy a fresh `Cargo.lock` from Buck2.
{
  lib,
  fetchFromGitHub,
  makeBinaryWrapper,
  installShellFiles,
  removeReferencesTo,
  fenix,
  makeRustPlatform,
  openssl,
  pkg-config,
  protobuf,
  sqlite,
  watchman,
}:
let
  rustPlatform = makeRustPlatform {
    cargo = toolchain;
    rustc = toolchain;
  };
  pname = "buck2";
  git_rev = "d4ad08a7e424eeaea5dc14eb0996285306cddc7a";

  src = fetchFromGitHub {
    owner = "MercuryTechnologies";
    repo = pname;
    rev = git_rev;
    hash = "sha256-XPatFleOD/3GzS2rubnKhT+Kmj9Hat9y5dygHWkEo0s=";
  };

  toolchain = fenix.fromToolchainFile {
    dir = src;
    sha256 = "sha256-Lz2Wx4xpZH0Nwgmq5VMVB5PsEJiPoQEXZ8OZCRUXPgE=";
  };
in
rustPlatform.buildRustPackage {
  inherit pname src;
  version = "git-${git_rev}";

  # Please avoid patching here - make one to mwb's repository and update off of mercury-head at https://github.com/MercuryTechnologies/buck2
  # See the README at https://github.com/MercuryTechnologies/buck2/
  patches = [ ];

  cargoLock = {
    lockFile = ./Cargo.lock;

    # We give these hashes explicitly to speed up Nix evaluation (allowBuiltinFetchGit blocks evaluation on git fetch!).
    # Get this stanza from `buck run nix//tools/nix-prefetch-cargo nix/packages/buck2-source/Cargo.lock`
    outputHashes = {
      "hyper-1.9.0" = "sha256-XnUOQYfPa+LKOx7aKz5wv4tL9hXirJ7UkrMBiM7bHb4=";
      "perf-event-0.4.8" = "sha256-Mvfp41Q9g9Z9xgdzFEdIdH/96YeCxrrSl2Vsm6geGMQ=";
      "perf-event-open-sys-5.0.0" = "sha256-Mvfp41Q9g9Z9xgdzFEdIdH/96YeCxrrSl2Vsm6geGMQ=";
      "probminhash-0.1.12" = "sha256-8IzGV6QDvyBPavICUB4j/VABBkplGa+sSsIz1OD35ik=";
      "sorted_vector_map-0.2.0" = "sha256-+6uh2hNKE7gHl756rtkpd6U2RDsQKLo2RVJ2OFqloVg=";
      "tonic-0.14.5" = "sha256-bf88XZMzeplglunUDOU5XWFgKpbzoVV1r4Sj3qvhOHQ=";
      "tonic-build-0.14.5" = "sha256-bf88XZMzeplglunUDOU5XWFgKpbzoVV1r4Sj3qvhOHQ=";
      "tonic-prost-0.14.5" = "sha256-bf88XZMzeplglunUDOU5XWFgKpbzoVV1r4Sj3qvhOHQ=";
      "tonic-prost-build-0.14.5" = "sha256-bf88XZMzeplglunUDOU5XWFgKpbzoVV1r4Sj3qvhOHQ=";
    };
  };

  postPatch = ''
    cp ${./Cargo.lock} Cargo.lock
    chmod +w Cargo.lock  # Huh???
    # tonic-health and tonic-reflection are listed as patches in Cargo.toml but
    # are unused ([patch.unused] in Cargo.lock). Cargo still validates them offline,
    # but the nix vendor dir omits [[patch.unused]] packages, so remove these entries
    # to avoid offline validation failures.
    sed -i '/tonic-health.*edef1c/d; /tonic-reflection.*edef1c/d' Cargo.toml
  '';

  nativeBuildInputs = [
    installShellFiles
    protobuf
    pkg-config
    makeBinaryWrapper
    removeReferencesTo
  ];

  buildInputs = [
    openssl
    sqlite
  ];

  env = {
    BUCK2_BUILD_PROTOC = "${protobuf}/bin/protoc";
    BUCK2_BUILD_PROTOC_INCLUDE = "${protobuf}/include";
    # Allows accessing tokio's unstable runtime metrics
    RUSTFLAGS = "--cfg=tokio_unstable";
  };

  doCheck = false;
  dontStrip = true; # cargo handles stripping; we scrub store paths in postInstall
  disallowedReferences = [ toolchain ];

  postInstall = ''
    mv $out/bin/buck2     $out/bin/buck
    ln -sfv $out/bin/buck $out/bin/buck2
    mv $out/bin/starlark  $out/bin/buck2-starlark
    mv $out/bin/read_dump $out/bin/buck2-read_dump

    installShellCompletion --cmd buck2 \
      --bash <( $out/bin/buck2 completion bash ) \
      --fish <( $out/bin/buck2 completion fish ) \
      --zsh <( $out/bin/buck2 completion zsh )

    # We wrap the buck2 so that it can never not have a watchman. This allows
    # for nix run .#buck2-source to work.
    wrapProgram $out/bin/buck \
      --prefix PATH : ${lib.makeBinPath [ watchman ]}

    # Scrub nightly Rust toolchain store paths from ALL output files.
    # Without this, panic strings in .rodata retain /nix/store paths that
    # trick Nix's reference scanner into pulling ~1.8 GiB of toolchain
    # into the runtime closure.
    find $out -type f -exec remove-references-to -t ${toolchain} {} +
  '';

  meta = with lib; {
    description = "Build system, successor to Buck";
    homepage = "https://buck2.build/";
    changelog = "https://github.com/facebook/buck2/blob/main/CHANGELOG.md";
    license = licenses.asl20;
    maintainers = [ ];
    platforms = platforms.linux ++ platforms.darwin;
    mainProgram = "buck2";
  };
}
