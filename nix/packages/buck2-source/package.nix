# SPDX-FileCopyrightText: 2026 Austin Seipp
# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

# Nix expression to build Buck2 from source.
# Based, in part, on https://github.com/thoughtpolice/buck2-nix/blob/c602d0f44f03310a89f209a322bb122b0d3c557a/buck/nix/buck2/default.nix
#
# To update Buck2:
# - change the `gitRev`, `srcHash` and `toolchainHash` attributes in
#   `currentArgs` below.
# - copy a fresh `Cargo.lock` from Buck2 and refresh `cargoLock.outputHashes`.
#
# `buildBuck2` is parameterised over exactly those inputs so that we can build
# more than one Buck2 out of this file; see `nextArgs` below.
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
  diffutils,
  runCommand,
  watchman,
}:
let
  # The Buck2 everyone gets as `pkgs.buck2-source`.
  currentArgs = {
    gitRev = "780ef1343928ea055b45ef8b03db9d834b84f60f";
    srcHash = "sha256-yAxegt5hKRFi6twj+75HmUFzhNFJXxByS2nRvEjQUzs=";
    toolchainHash = "sha256-KyNTI/ZRO/v6w+nJTxj8JjRMX4EmViw2pCTbRKYyILo=";

    # scuffed fix to unused patched dependencies. we could (and have later)
    # fixed them in git.
    prePatch = ''
      sed -Ei -e '\#tonic-health = \{ git = "https://github.com/edef1c/tonic.git"#d' \
        -e '\#tonic-reflection = \{ git = "https://github.com/edef1c/tonic.git"#d' \
        Cargo.toml
    '';

    cargoLock = {
      lockFile = ./Cargo.lock;
      outputHashes = {
        "hyper-1.9.0" = "sha256-XnUOQYfPa+LKOx7aKz5wv4tL9hXirJ7UkrMBiM7bHb4=";
        "opentelemetry-0.32.0" = "sha256-Lt4FkCsx7RFWYtBYzVqfwGfITB8PRc2FSrdYKSmEol8=";
        "opentelemetry-http-0.32.0" = "sha256-Lt4FkCsx7RFWYtBYzVqfwGfITB8PRc2FSrdYKSmEol8=";
        "opentelemetry-otlp-0.32.0" = "sha256-Lt4FkCsx7RFWYtBYzVqfwGfITB8PRc2FSrdYKSmEol8=";
        "opentelemetry-proto-0.32.0" = "sha256-Lt4FkCsx7RFWYtBYzVqfwGfITB8PRc2FSrdYKSmEol8=";
        "opentelemetry-semantic-conventions-0.32.1" = "sha256-Lt4FkCsx7RFWYtBYzVqfwGfITB8PRc2FSrdYKSmEol8=";
        "opentelemetry_sdk-0.32.1" = "sha256-Lt4FkCsx7RFWYtBYzVqfwGfITB8PRc2FSrdYKSmEol8=";
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
  };

  # Staging ground for the next Buck2, exposed as `buck2-source.passthru.next`
  # so it can be built and cached without changing what anyone gets by default.
  #
  # You can use this from any dev shell like:
  # `nix develop -f shell.nix exclude.all.passthru.buck2-next`
  #
  # Each version gets its own lock file, toolchain hash, etc, since they pretty
  # much always change.
  nextArgs = {
    # See: https://github.com/MercuryTechnologies/buck2/commits/mercury-head
    gitRev = "fe235292a4bf27274b48520528ea748284a6a53f";
    srcHash = "sha256-4hlhru9BHXOfOp5uyR9s3i/jnqTn23Vrxygmez4DVy4=";
    toolchainHash = "sha256-kEslngyDh0HeelBSXJ/DWdEjMsce4jatUcB1mNtlRMA=";

    cargoLock = {
      lockFile = builtins.path {
        name = "Cargo.lock";
        path = ./Cargo.lock.next;
      };

      # We give these hashes explicitly to speed up Nix evaluation (allowBuiltinFetchGit blocks evaluation on git fetch!).
      # Get this stanza from `buck run nix//tools/nix-prefetch-cargo -- nix/packages/buck2-source/Cargo.lock`
      outputHashes = {
        "filedescriptor-0.8.3" = "sha256-V6WvkNZryYofarsyfcmsuvtpNJ/c3O+DmOKNvoYPbmA=";
        "finl_unicode-1.3.0" = "sha256-38S6XH4hldbkb6NP+s7lXa/NR49PI0w3KYqd+jPHND0=";
        "hyper-1.10.1" = "sha256-5Jwxx+cafnawCBV+6VS461uL2TGht8k6xPBf2tAhcO0=";
        "opentelemetry-0.32.0" = "sha256-Lt4FkCsx7RFWYtBYzVqfwGfITB8PRc2FSrdYKSmEol8=";
        "opentelemetry-http-0.32.0" = "sha256-Lt4FkCsx7RFWYtBYzVqfwGfITB8PRc2FSrdYKSmEol8=";
        "opentelemetry-otlp-0.32.0" = "sha256-Lt4FkCsx7RFWYtBYzVqfwGfITB8PRc2FSrdYKSmEol8=";
        "opentelemetry-proto-0.32.0" = "sha256-Lt4FkCsx7RFWYtBYzVqfwGfITB8PRc2FSrdYKSmEol8=";
        "opentelemetry-semantic-conventions-0.32.1" = "sha256-Lt4FkCsx7RFWYtBYzVqfwGfITB8PRc2FSrdYKSmEol8=";
        "opentelemetry_sdk-0.32.1" = "sha256-Lt4FkCsx7RFWYtBYzVqfwGfITB8PRc2FSrdYKSmEol8=";
        "perf-event-0.4.8" = "sha256-Mvfp41Q9g9Z9xgdzFEdIdH/96YeCxrrSl2Vsm6geGMQ=";
        "perf-event-open-sys-5.0.0" = "sha256-Mvfp41Q9g9Z9xgdzFEdIdH/96YeCxrrSl2Vsm6geGMQ=";
        "termwiz-0.24.0" = "sha256-V6WvkNZryYofarsyfcmsuvtpNJ/c3O+DmOKNvoYPbmA=";
        "tonic-0.14.6" = "sha256-yzev8mwMhJS3iSAsyCC6TH7kSDcRLNghDdFijAuI6Ws=";
        "tonic-build-0.14.6" = "sha256-yzev8mwMhJS3iSAsyCC6TH7kSDcRLNghDdFijAuI6Ws=";
        "tonic-prost-0.14.6" = "sha256-yzev8mwMhJS3iSAsyCC6TH7kSDcRLNghDdFijAuI6Ws=";
        "tonic-prost-build-0.14.6" = "sha256-yzev8mwMhJS3iSAsyCC6TH7kSDcRLNghDdFijAuI6Ws=";
        "vtparse-0.7.0" = "sha256-V6WvkNZryYofarsyfcmsuvtpNJ/c3O+DmOKNvoYPbmA=";
        "wezterm-bidi-0.2.3" = "sha256-V6WvkNZryYofarsyfcmsuvtpNJ/c3O+DmOKNvoYPbmA=";
        "wezterm-blob-leases-0.1.1" = "sha256-V6WvkNZryYofarsyfcmsuvtpNJ/c3O+DmOKNvoYPbmA=";
        "wezterm-cell-0.1.0" = "sha256-V6WvkNZryYofarsyfcmsuvtpNJ/c3O+DmOKNvoYPbmA=";
        "wezterm-char-props-0.1.3" = "sha256-V6WvkNZryYofarsyfcmsuvtpNJ/c3O+DmOKNvoYPbmA=";
        "wezterm-color-types-0.3.0" = "sha256-V6WvkNZryYofarsyfcmsuvtpNJ/c3O+DmOKNvoYPbmA=";
        "wezterm-dynamic-0.2.1" = "sha256-V6WvkNZryYofarsyfcmsuvtpNJ/c3O+DmOKNvoYPbmA=";
        "wezterm-dynamic-derive-0.1.1" = "sha256-V6WvkNZryYofarsyfcmsuvtpNJ/c3O+DmOKNvoYPbmA=";
        "wezterm-escape-parser-0.1.0" = "sha256-V6WvkNZryYofarsyfcmsuvtpNJ/c3O+DmOKNvoYPbmA=";
        "wezterm-input-types-0.1.0" = "sha256-V6WvkNZryYofarsyfcmsuvtpNJ/c3O+DmOKNvoYPbmA=";
        "wezterm-surface-0.1.0" = "sha256-V6WvkNZryYofarsyfcmsuvtpNJ/c3O+DmOKNvoYPbmA=";
      };
    };
  };

  # Build one Buck2 from a given source revision, Rust toolchain and lockfile.
  #
  # `cargoLock` is passed straight through to `buildRustPackage`, so it carries
  # both the lockfile and its `outputHashes` - those two always have to move
  # together.
  buildBuck2 =
    {
      gitRev,
      srcHash,
      toolchainHash,
      cargoLock,
      prePatch ? "",
      # Extra attributes to expose on the wrapper's `passthru`.
      passthru ? { },
    }:
    let
      rustPlatform = makeRustPlatform {
        cargo = toolchain;
        rustc = toolchain;
      };
      pname = "buck2";

      src = fetchFromGitHub {
        owner = "MercuryTechnologies";
        repo = pname;
        rev = gitRev;
        hash = srcHash;
      };

      toolchain = fenix.fromToolchainFile {
        dir = src;
        sha256 = toolchainHash;
      };

      unwrapped = rustPlatform.buildRustPackage {
        inherit pname src cargoLock;
        version = "git-${gitRev}";

        # Please avoid patching here - make one to mwb's repository and update off of mercury-head at https://github.com/MercuryTechnologies/buck2
        # See the README at https://github.com/MercuryTechnologies/buck2/
        patches = [ ];

        inherit prePatch;
        postPatch = ''
          cp ${cargoLock.lockFile} Cargo.lock
          chmod +w Cargo.lock  # Huh???
        '';

        nativeBuildInputs = [
          installShellFiles
          protobuf
          pkg-config
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
          # `buck --version` should return the correct commit hash.
          # This is also sent in telemetry, so it's important we get it right.
          BUCK2_SET_EXPLICIT_VERSION = gitRev;
        };

        doCheck = false;
        dontStrip = true; # cargo handles stripping; we scrub store paths in postInstall
        disallowedReferences = [ toolchain ];

        postInstall = ''
          mv $out/bin/buck2     $out/bin/buck
          ln -sfv buck $out/bin/buck2
          mv $out/bin/starlark  $out/bin/buck2-starlark
          mv $out/bin/read_dump $out/bin/buck2-read_dump

          installShellCompletion --cmd buck2 \
            --bash <( $out/bin/buck2 completion bash ) \
            --fish <( $out/bin/buck2 completion fish ) \
            --zsh <( $out/bin/buck2 completion zsh )

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
      };
    in
    # Separate wrapping derivation so that we can change the $PATH without
    # rebuilding the entire buck2.
    runCommand "${unwrapped.name}-wrapped"
      {
        nativeBuildInputs = [
          makeBinaryWrapper
          removeReferencesTo
        ];
        inherit (unwrapped) meta;
        passthru = {
          inherit unwrapped;
        } // passthru;
        disallowedReferences = [ unwrapped ];
      }
      ''
        cp -R ${unwrapped} $out
        chmod -R +w $out
        mv $out/bin/buck $out/bin/.buck-wrapped
        # We wrap the buck2 so that it can never not have a watchman. This allows
        # for nix run .#buck2-source to work.
        #
        # This also looks at BUCK2_ROLLOUT_BIN so that references to buck2 via
        # PATH get the intended buck2 from the rollout mechanism even if PATH
        # gets this derivation output prepended.
        cat > $out/bin/buck <<'EOF'
        #!/bin/sh
        export PATH=${
          lib.makeBinPath [
            watchman
            diffutils
          ]
        }:$PATH
        exe="@selfdir@/.buck-wrapped"
        # don't print the message if this redirection is a no-op
        if [[ -n "$BUCK2_ROLLOUT_BIN" && -x "$BUCK2_ROLLOUT_BIN/buck" && "$BUCK2_ROLLOUT_BIN" != "$selfdir" ]]; then
          exe="$BUCK2_ROLLOUT_BIN/buck"
          echo "buck2 wrapper: using $BUCK2_ROLLOUT_BIN/buck due to \$BUCK2_ROLLOUT_BIN" >&2
          unset BUCK2_ROLLOUT_BIN
        fi
        exec "$exe" "$@"
        EOF
        substituteInPlace "$out/bin/buck" --replace-fail @selfdir@ "$out/bin"
        chmod +x $out/bin/buck
        find $out/share -type f -exec remove-references-to -t ${unwrapped} '{}' +
      '';
in
buildBuck2 (
  currentArgs
  // {
    passthru = {
      next = buildBuck2 nextArgs;
    };
  }
)
