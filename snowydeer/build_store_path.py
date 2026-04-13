# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
Builds a store path from some given dependency list and some contents.
"""

import argparse
import tempfile
import json
import dataclasses
from pathlib import Path
import subprocess
import typing
import logging

logging.basicConfig(
    format="{levelname} {name}: {message}", style="{", level=logging.INFO
)

StorePathHash = str

_EXE_PATHS = None


@dataclasses.dataclass(frozen=True)
class ExePaths:
    ripgrep: str
    import_ca: str | None
    """
    import-ca executable. If not present, we just use the native Lix 2.95 feature.
    """

    @staticmethod
    def get() -> "ExePaths":
        assert _EXE_PATHS
        return _EXE_PATHS


@dataclasses.dataclass(frozen=True)
class StorePath:
    hash_part: StorePathHash
    name_part: str

    @classmethod
    def split(cls, as_str: str) -> typing.Self:
        """Splits into hash and name parts"""
        (hash_part, _, name_part) = as_str.removeprefix("/nix/store/").partition("-")
        return cls(hash_part=hash_part, name_part=name_part)

    def __str__(self) -> str:
        return f"/nix/store/{self.hash_part}-{self.name_part}"


def deserialize_paths_json(paths_json: dict) -> set[StorePath]:
    """
    Deserializes the store paths out of snowydeer.bxl, which are in a funny
    shape due to limitations of tsets where we can't merge the stuff ahead of
    time.
    """

    def flatten2(xsss: list[list[str]]):
        return set(x for xss in xsss for xs in xss for x in xs)

    return set(StorePath.split(p) for p in paths_json["paths_old"]) | set(
        StorePath.split(p) for p in flatten2(paths_json["paths_new"])
    )


def ref_scan(
    temp_dir: Path, nar_file: Path, possible_refs: set[StorePath]
) -> set[StorePath]:
    """
    Implements scanForReferences as documented in Fig 5.12 of Eelco
    Dolstra's PhD thesis, available at
    https://edolstra.github.io/pubs/phd-thesis.pdf

    Takes a superset of the actual references of a store path and scans for
    their presence in a NAR file using ripgrep (because we have a fast string
    scanning implementation at home, so to speak).
    """
    store_path_map = {store_path.hash_part: store_path for store_path in possible_refs}

    patterns_file = temp_dir / "patterns"

    with open(patterns_file, "w") as patterns:
        for line in store_path_map.keys():
            patterns.write(line + "\n")

    proc = subprocess.run(
        [
            ExePaths.get().ripgrep,
            # print just the matched part
            "--only-matching",
            # treat binary as text
            "--text",
            "-uu",
            # don't use actual regex
            "--fixed-strings",
            # don't utf8
            "--encoding",
            "none",
            "--file",
            patterns_file,
            nar_file,
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    # ripgrep returns 0 if a match was found, 1 if a match was found but no
    # other errors. Both of these are ok. Other codes mean something is
    # actually wrong.
    if proc.returncode not in [0, 1]:
        raise subprocess.CalledProcessError(
            proc.returncode, proc.args, output=proc.stdout, stderr=proc.stderr
        )
    matched_paths = (x for x in proc.stdout.splitlines() if x)

    return set(store_path_map[hash_part] for hash_part in matched_paths)


def dump_nar(path: Path, to: Path):
    with open(to, "wb") as to_handle:
        subprocess.check_call(["nix", "nar", "dump-path", path], stdout=to_handle)


def export_path(path: Path, possible_refs: set[StorePath], name: str) -> str:
    with tempfile.TemporaryDirectory("snowydeer") as temp_dir:
        temp_dir = Path(temp_dir)

        nar_path = temp_dir / "out.nar"
        dump_nar(path, nar_path)

        refs = ref_scan(
            temp_dir=temp_dir, nar_file=nar_path, possible_refs=possible_refs
        )
        logging.info("references: %r", refs)

        import_ca = ExePaths.get().import_ca
        if import_ca:
            refs_file = temp_dir / "refs.txt"
            refs_file.write_text("\n".join(str(ref) for ref in refs))

            return subprocess.check_output(
                [
                    import_ca,
                    "--references-file",
                    refs_file,
                    "--nar-file",
                    nar_path,
                    "--name",
                    name,
                ],
                text=True,
            )
        else:
            refs_file = temp_dir / "refs.json"
            refs_file.write_text(json.dumps([str(ref) for ref in refs]))

            return subprocess.check_output(
                [
                    "nix",
                    "store",
                    "add-path",
                    "--references-list-json",
                    refs_file,
                    "--name",
                    name,
                    path,
                ],
                text=True,
            )


def get_dependency_closure(paths: set[StorePath]) -> set[StorePath]:
    """
    Gets the *full* dependency closure including transitive deps out of Nix,
    since Buck only tells us the direct Nix dependencies, but transitive ones
    are likely to also be referenced.

    This will become enormous pretty fast with ghc/haskell stuff being
    included, so ref scanning should NOT be doing O(n^2*m) stuff.
    """
    # XXX: We have actually cast too wide a net while retrieving store paths to
    # consider, which causes Nix to try to realise some of them that weren't on
    # the machine to begin with; we probably should collect a more correct set
    # instead. In particular, we consider the hie output in addition to out,
    # even if hie wasn't ever demanded because we don't have an easy way to
    # actually track that.
    #
    # However, if they're not on the machine they are not possible to depend
    # on, so we can just filter on the ones that pass lstat. The Nix store
    # tries very hard to ensure that all paths that exist have their transitive
    # closure also exist, so it's no problem to get the transitive closure of
    # anything that exists on the machine.
    extant_paths = set()
    for path in paths:
        try:
            Path(str(path)).lstat()
            extant_paths.add(path)
        except FileNotFoundError:
            pass

    proc = subprocess.Popen(
        ["nix", "path-info", "--recursive", "--stdin"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    )
    (stdout, _) = proc.communicate(input="\n".join(str(path) for path in extant_paths))

    new_paths = (path for path in stdout.splitlines() if path)
    return set(StorePath.split(path) for path in new_paths)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--ripgrep-exe",
        default="rg",
        help="Path to a ripgrep executable",
    )
    parser.add_argument(
        "--import-ca-exe",
        help="Path to the import-ca executable",
    )
    parser.add_argument(
        "--paths-json",
        required=True,
        type=argparse.FileType("r"),
        help="JSON file with all the paths that might appear in the closure",
    )
    parser.add_argument(
        "--artifact",
        required=True,
        help="Artifact (file or directory) to import to Nix store",
    )
    parser.add_argument(
        "--name",
        required=True,
        help="Name of the store path",
    )
    parser.add_argument(
        "--write-path-to",
        type=argparse.FileType("w"),
        default="-",
        help="Path to write the final store path into",
    )

    args = parser.parse_args()

    global _EXE_PATHS
    _EXE_PATHS = ExePaths(ripgrep=args.ripgrep_exe, import_ca=args.import_ca_exe)

    with args.write_path_to, args.paths_json:
        data = json.load(args.paths_json)
        possible_refs = deserialize_paths_json(data)
        possible_refs = get_dependency_closure(possible_refs)
        path = export_path(Path(args.artifact), possible_refs, args.name)
        if args.write_path_to:
            args.write_path_to.write(path)


if __name__ == "__main__":
    main()
