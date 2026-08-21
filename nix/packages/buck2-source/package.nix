# SPDX-FileCopyrightText: 2026 Austin Seipp
# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

# Nix expression to build Buck2 from source.
# Based, in part, on https://github.com/thoughtpolice/buck2-nix/blob/c602d0f44f03310a89f209a322bb122b0d3c557a/buck/nix/buck2/default.nix
#
# To update Buck2, run `./update.py` in this directory; it rewrites
# `versions.json` and the lock files from the tips of the upstream branches.
#
# `buildBuck2` is parameterised over the per-version inputs so that we can build
# more than one Buck2 out of this file; see `versions.json`.
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
  # Pins for both Buck2s, written by `./update.py`: git revision, source hash,
  # Rust toolchain manifest hash and the `outputHashes` for the lock file's git
  # dependencies.
  #
  # Each version gets its own lock file, toolchain hash, etc, since they pretty
  # much always change.
  versions = lib.importJSON ./versions.json;

  # Turn one entry of `versions.json` into `buildBuck2` arguments.
  #
  # The lock file lives beside the pins rather than inside them because Nix
  # needs a literal path here; `update.py` knows the same mapping.
  argsFor = lockFile: version: {
    inherit (version) gitRev srcHash toolchainHash;

    cargoLock = {
      # Both lock files are called `Cargo.lock` in the store so that renaming
      # a slot's file doesn't rebuild it.
      lockFile = builtins.path {
        name = "Cargo.lock";
        path = lockFile;
      };

      # We give these hashes explicitly to speed up Nix evaluation (allowBuiltinFetchGit blocks evaluation on git fetch!).
      inherit (version) outputHashes;
    };
  };

  # The Buck2 everyone gets as `pkgs.buck2-source`.
  currentArgs = argsFor ./Cargo.lock versions.current;

  # Staging ground for the next Buck2, exposed as `buck2-source.passthru.next`
  # so it can be built and cached without changing what anyone gets by default.
  #
  # You can use this from any dev shell like:
  #     nix develop -f shell.nix exclude.all.passthru.buck2-next
  #
  # Or from your `.envrc.local` like:
  #     export MWB_SHELL_FLAKE_ATTR=exclude.all.passthru.buck2-next
  nextArgs = argsFor ./Cargo.lock.next versions.next;

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

        # This revision enables `starlark/pagable`, which makes `cargo-auditable`'s
        # `cargo metadata` call blow up on `starlark_map`.
        #
        # I think this might be blocked on https://linear.app/mercury/issue/DUX-3850/update-nixpkgs-2025-q3
        auditable = false;

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
        selfdir="@selfdir@"
        exe="$selfdir/.buck-wrapped"
        # don't print the message if this redirection is a no-op
        if [ -n "$BUCK2_ROLLOUT_BIN" ] && [ -x "$BUCK2_ROLLOUT_BIN/buck" ] && [ "$BUCK2_ROLLOUT_BIN" != "$selfdir" ]; then
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
