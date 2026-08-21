# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

{
  fetchFromGitHub,
  fenix,
  lib,
  makeRustPlatform,
}:

let
  src = fetchFromGitHub {
    owner = "facebookincubator";
    repo = "buck2-change-detector";
    rev = "7a632871f376cb04bc007829c8dd7d536078ae4a";
    hash = "sha256-f0MHJ8GPh0Qp7jGcsoyU+udzu6fDDoLvO10a8/LhPyM=";
  };
  toolchain = fenix.fromToolchainFile {
    dir = src;
    sha256 = "sha256-NvWKV8CXj8AQXESvz5uGr6qv0JF0UHUdjYb2murEG/A=";
  };
  rustPlatform = makeRustPlatform {
    cargo = toolchain;
    rustc = toolchain;
  };
in
rustPlatform.buildRustPackage {
  pname = "buck2-change-detector";
  version = "2026-07-20";

  inherit src;

  cargoLock = {
    lockFile = ./Cargo.lock;
    outputHashes = {
      "fbinit-0.2.0" = "sha256-WjvCw/aiOO3uBGnv+EoQq9suAlsLwauRREFOoh/4mwU=";
      "fbinit-tokio-0.1.2" = "sha256-WjvCw/aiOO3uBGnv+EoQq9suAlsLwauRREFOoh/4mwU=";
      "fbinit_macros-0.2.0" = "sha256-WjvCw/aiOO3uBGnv+EoQq9suAlsLwauRREFOoh/4mwU=";
      "sampling-0.1.0" = "sha256-WjvCw/aiOO3uBGnv+EoQq9suAlsLwauRREFOoh/4mwU=";
      "scuba-0.1.0" = "sha256-WjvCw/aiOO3uBGnv+EoQq9suAlsLwauRREFOoh/4mwU=";
      "scuba_sample-0.1.0" = "sha256-WjvCw/aiOO3uBGnv+EoQq9suAlsLwauRREFOoh/4mwU=";
      "scuba_sample_builder-0.1.0" = "sha256-WjvCw/aiOO3uBGnv+EoQq9suAlsLwauRREFOoh/4mwU=";
      "scuba_sample_client-0.1.0" = "sha256-WjvCw/aiOO3uBGnv+EoQq9suAlsLwauRREFOoh/4mwU=";
      "scuba_sample_derive-0.1.0" = "sha256-WjvCw/aiOO3uBGnv+EoQq9suAlsLwauRREFOoh/4mwU=";
    };
  };

  # Upstream does not commit its generated lockfile. Keep the resolved graph
  # beside this derivation and place it into the source before Cargo setup.
  postUnpack = ''
    cp ${./Cargo.lock} "$sourceRoot/Cargo.lock"
  '';

  cargoBuildFlags = [
    "--package"
    "btd"
    "--package"
    "targets"
  ];

  cargoTestFlags = [
    "--package"
    "btd"
    "--package"
    "targets"
  ];

  meta = {
    description = "Determine affected Buck2 targets from source changes";
    homepage = "https://github.com/facebookincubator/buck2-change-detector";
    license = with lib.licenses; [
      asl20
      mit
    ];
    mainProgram = "btd";
  };
}
