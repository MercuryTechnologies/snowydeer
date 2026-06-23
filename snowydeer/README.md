<!--
SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.

SPDX-License-Identifier: MIT OR Apache-2.0
-->

# snowydeer

Snowydeer is a conversion tool between buck2 targets and Nix store paths.
It also has a container building tool (see the [Containers](#containers) section).

It's used as part of deploying buck2 built artifacts to servers.
It operates in five stages:
- A package target is defined using `//snowydeer:package.bzl`, which creates a file tree with the desired contents as a normal buck target

  Notably this builds static binaries for everything in `binaries` so that they don't depend on GHC or have issues with dynamic linked deps.
- `snowydeer.bxl` finds all the candidate nix dependencies in the buck2 dependency graph of the desired target
- `build_store_path` turns that target's output into a NAR and reference scans to find what the dependencies should be
- The NAR is imported into the Nix store via [Lix 2.95's --references-list-json][lix-ca] or `import_ca`.

[lix-ca]: https://gerrit.lix.systems/c/lix/+/5205

# Getting started

Set up the Nix cache (we try to do it with envrc, but needs configuring in `/etc/nix/nix.conf` if not trusted-user) with:

```
extra-substituters = https://cache.oss.mercury.com
extra-trusted-public-keys = cache.oss.mercury.com-1:COfsgEgHMrBhMvGoLWuNH5RDgub3/MT32n8kK50m2dc=
```

Run: `direnv allow` in the repo root.
This will get you a simple dev shell with buck2.

From here, you can try out parts of the Snowydeer system.

## Usage

Define a `snowydeer_package` Buck target (works on other targets, there's nothing special about them, but they give you a bin directory with static binaries).

Then:

```
$ cat "$(buck bxl //snowydeer:snowydeer.bxl:main -- --target //snowydeer/demo:hello_pkg)"
/nix/store/wgmy5n9902wdxc8805zw4xjnnx26cwv4-hello_pkg
```

Result: a content addressed store path with the correct references, based on the buck2 target:

```
$ nix path-info --json /nix/store/wgmy5n9902wdxc8805zw4xjnnx26cwv4-hello_pkg | jq .
[
  {
    "ca": "fixed:r:sha256:1i30qi761zzv319and0yilk030xfrvblnllp5bisy0xxaxy66j0h",
    "narHash": "sha256-EEhjfFe9A6/jKpdSS9fOroMBJo0eNKtSGPv/YE7EYMQ=",
    "narSize": 3007400,
    "path": "/nix/store/wgmy5n9902wdxc8805zw4xjnnx26cwv4-hello_pkg",
    "references": [
      "/nix/store/6jlvf7clxssbas581lgiykk0giwf4cmw-numactl-2.0.18",
      "/nix/store/92xdlb1wksbxrrby7naingaqamag50ip-libffi-3.5.2",
      "/nix/store/cw6hdc2f0fpf8sscbxfz3d5x1yymys31-gmp-with-cxx-6.3.0",
      "/nix/store/fh5kkgxw6vby5c8747qificcbbalwcpf-gcc-15.2.0-lib",
      "/nix/store/nmq81hidzwij3c7vyiazwg2l74vnxkar-glibc-2.42-51"
    ],
    "registrationTime": 1775703032,
    "valid": true
  }
]

```

## What on earth witchery is this?

- Retrieve all nix store paths in the *buck2* closure of the target.
- Get the Nix level closure (i.e. transitive dependencies of any store paths that appeared).
- Pack into a NAR file so it can be ref scanned and imported to the store.
- Ref scan for the hash parts of the entire Nix level closure (with ripgrep) to determine runtime dependencies set.
- Load into Nix store with the given NAR and runtime dependencies set as if it is a content-addressed derivation output.

## Retrieving the store path afterwards from nix

```nix
# Hack from https://git.lix.systems/lix-project/lix/issues/402#issuecomment-5889
fabricateStringContext = path: builtins.appendContext path { ${path} = { path = true; }; };
```

Then give it the store path as a string.

# Containers

Snowydeer Container is an easy way to build containers from Buck targets, based on Snowydeer and [nixpkgs `dockerTools`][dockerTools].

Since it's written in Haskell, you'll have to run:

```
$ buck run //haskell:toolchain_libs
```

to populate the toolchain libraries files in the repo so that anything works.
This step may become unnecessary in the future.

[dockerTools]: https://nixos.org/manual/nixpkgs/stable/#sec-pkgs-dockerTools

Then set up a container policy file `~/.config/containers/policy.json` to allow importing containers (`podman load` doesn't accept unsigned images and there's no CLI option to do so):

```json
{
  "default": [
    {
      "type": "insecureAcceptAnything"
    }
  ]
}
```

Finally, you can build and run a container:

```
$ buck run //snowydeer/demo:hello_container -- save | podman load
...
Writing manifest to image destination
Loaded image: localhost/hello_container:latest

$ podman run localhost/hello_container:latest
Hello world
```

You can also push to a registry, which will automatically tag the image as the Git revision as well as `latest`:

```
$ buck run //snowydeer/demo:hello_container -- push ghcr.io/myaccount/myimage
```

## Metadata

Snowydeer Container generates a rich set of metadata automatically and staples it to the image:

```
$ podman inspect localhost/hello_container:latest | jq '.[].Labels'
{
  "org.opencontainers.image.description": "Hello world, in a container",
  "org.opencontainers.image.revision": "1890ac0b360fdc16d25329339d97f906835f0cb1",
  "org.opencontainers.image.source": "root//snowydeer/demo:hello_container (prelude//platforms:default#8907a3b63c392798)",
  "org.opencontainers.image.title": "root//snowydeer/demo:hello_container"
}
```

Internally at Mercury we also mandate an owning team and a runbook URL: the tools don't let you deploy code that can't be operated.

## Defining containers

Containers are defined with a build target as follows:

```python
load("//snowydeer:container.bzl", "snowydeer_container")

# This is a wrapper for
# https://nixos.org/manual/nixpkgs/stable/#ssec-pkgs-dockerTools-streamLayeredImage-inputs
snowydeer_container(
    name = "hello_container",
    # No way to do store path references here; need to be put in place as
    # absolute paths using `content`.
    #
    # This command is what will be run inside tini.
    cmd = ["/bin/hello"],

    # contents= in Nix docker tools; will be symlinked into the root of the container.
    # This is a set of paths in addition to `main_contents`.
    contents = [
        # Snowydeer package dependencies
        ":hello_pkg",
        # Nix dependencies are allowed too!
        "toolchains//:ripgrep",
    ],

    # Required. Description of the image.
    description = "Hello world, in a container",

    # Optional. No store paths supported in here either.
    env = {"FOOBAR": "blah"},

    # These fast-changing paths are isolated into their own layers on top of
    # the image. We recommend putting the main application targets in the image
    # into here.
    #
    # Other paths will be intelligently layered into the image.
    main_contents = [
        ":hello_pkg",
        "toolchains//:ripgrep",
    ],

    # Optional. Expose TCP port 2003.
    ports = ["2003/tcp"],
)
```

## How does it work?

First, `container.bzl` creates a JSON file of the necessary data from Buck2 (included targets and their kind) to give to Snowydeer Container.
Snowydeer Container processes that information further and then calls Nix to build a `streamLayeredImage` streaming script.
Finally, it invokes that script to stream a tarball, either into a registry with the `copy` command or to stdout for `podman load` with the `save` command.

Unlike most Nix usage, Nix is *not* driving the build here: Snowydeer Container is just giving Nix a blob of JSON and it builds the container from that.
In order to do that, we use the trick mentioned above for recreating string contexts from thin air.

Snowydeer Container uses a clever layering pipeline to isolate the most frequently changing layers from the base layers.
We have documentation of how that works in `snowydeer/container/src/Snowydeer/Container/Pipeline.hs`.

You can see the process of actually building containers at `nix/packages/snowydeer/build-container.nix`; it's a pretty thin wrapper around `dockerTools.streamLayeredImage`.
