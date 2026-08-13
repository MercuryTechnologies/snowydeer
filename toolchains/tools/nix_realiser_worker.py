#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Realise Nix derivations for Buck2, coalescing concurrent requests.

We need to preserve the granular dependencies enabled by logically having one
nix_build for each dependency. However, many concurrent `nix build` invocations
adds a lot of overhead. We avoid that problem by simply serializing and batching,
making new requests form a queue for the next `nix build` batch.
"""

import argparse
import hashlib
import os
import queue
import subprocess
import sys
import threading
from concurrent import futures
from pathlib import Path

# This is a place to keep the roots created by nix build, which does not give
# control over --out-link locations independently for a batch.
# Alternatively, we could use AddIndirectRoot but then we have to talk to the
# daemon.
# This is intentionally not in the action's output directory, but it is in
# buck-out so that it is cleaned up by buck clean.
ROOT_DIR_NAME = "nix-realiser-roots"


class BadRequest(Exception):
    pass


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        raise BadRequest("{}: {}".format(self.prog, message))


def parse_request(argv):
    parser = _Parser(prog="nix_realiser_worker", fromfile_prefix_chars="@")
    parser.add_argument("--drv", required=True)
    parser.add_argument("--out-link", required=True, help="The declared output.")
    parser.add_argument("--store-path", required=True)
    parser.add_argument(
        "--option",
        nargs=2,
        action="append",
        default=[],
        help="Nix option override, from the flake's nixConfig.",
    )
    return parser.parse_args(argv)


class Job:
    def __init__(self, request):
        self.request = request
        self.done = threading.Event()
        self.error = None


class Realiser:
    """Realises derivations, coalescing whatever requests are in flight."""

    def __init__(self):
        self._queued = queue.SimpleQueue()
        self._root_dir = None
        threading.Thread(target=self._run_batches, daemon=True).start()

    def realise(self, job):
        """Realise one derivation; returns an error string, or None on success."""
        self._queued.put(job)
        job.done.wait()
        return job.error

    def _run_batches(self):
        while True:
            batch = self._next_batch()
            try:
                self._run_batch(batch)
            except Exception as e:
                for job in batch:
                    job.error = "nix_realiser_worker: {!r}".format(e)
            for job in batch:
                job.done.set()

    def _next_batch(self):
        # Requests arriving during a build wait in the queue and batch together.
        batch = [self._queued.get()]
        while not self._queued.empty():
            batch.append(self._queued.get())
        return batch

    def _run_batch(self, batch):
        # First batch for this worker instance.
        if self._root_dir is None:
            self._root_dir = _root_dir(batch[0].request.out_link)
            _prune_roots(self._root_dir)

        options = batch[0].request.option
        assert all(j.request.option == options for j in batch), "mixed nix options"

        drvs = sorted({job.request.drv for job in batch})
        error = self._nix_build(drvs, options)
        errors = dict.fromkeys(drvs, error)
        if error is not None and len(drvs) > 1:
            # Retry individually to isolate the failing one to avoid confusing errros.
            for drv in drvs:
                errors[drv] = self._nix_build([drv], options)

        for job in batch:
            job.error = errors[job.request.drv]
            if job.error is None:
                Path(job.request.out_link).symlink_to(job.request.store_path)

    def _nix_build(self, drvs, options):
        self._root_dir.mkdir(parents=True, exist_ok=True)
        digest = hashlib.sha1("\n".join(drvs).encode("utf-8")).hexdigest()[:16]
        command = ["nix", "build", "--print-build-logs", "--show-trace"]
        for name, value in options:
            command += ["--option", name, value]
        command += ["--out-link", str(self._root_dir / digest)]
        command += ["{}^*".format(drv) for drv in drvs]
        result = subprocess.run(
            command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE
        )
        if result.returncode != 0:
            return result.stderr.decode("utf-8", "replace")
        return None


def _root_dir(out_link):
    buck_out, isolation = Path(out_link).parts[:2]
    return Path(buck_out, isolation, ROOT_DIR_NAME)


def _prune_roots(root_dir):
    # With iterative builds this dir would grow really fast.
    # We only need one root per store path, and it's cheap to clean up duplicates here.
    rooted = set()
    if not root_dir.is_dir():
        return
    for link in sorted(root_dir.iterdir()):
        target = link.readlink()
        if target in rooted:
            link.unlink()
        else:
            rooted.add(target)


def realise_one(argv):
    # For when we're running without workers enabled.
    try:
        job = Job(parse_request(argv))
    except BadRequest as e:
        print(e, file=sys.stderr)
        return 2

    error = Realiser().realise(job)
    if error is None:
        return 0
    sys.stderr.write(error)
    return 1


def serve(socket_path):
    import grpc
    import worker_pb2

    realiser = Realiser()

    def execute(request, _context):
        argv = [arg.decode("utf-8") for arg in request.argv]
        try:
            job = Job(parse_request(argv))
        except BadRequest as e:
            return worker_pb2.ExecuteResponse(exit_code=2, stderr=str(e))
        error = realiser.realise(job)
        return worker_pb2.ExecuteResponse(
            exit_code=0 if error is None else 1, stderr=error or ""
        )

    server = grpc.server(futures.ThreadPoolExecutor(max_workers=1024))
    server.add_generic_rpc_handlers(
        (
            grpc.method_handlers_generic_handler(
                "worker.Worker",
                {
                    "Execute": grpc.unary_unary_rpc_method_handler(
                        execute,
                        request_deserializer=worker_pb2.ExecuteCommand.FromString,
                        response_serializer=worker_pb2.ExecuteResponse.SerializeToString,
                    )
                },
            ),
        )
    )
    server.add_insecure_port("unix://{}".format(socket_path))
    server.start()
    server.wait_for_termination()


if __name__ == "__main__":
    socket_path = os.environ.get("WORKER_SOCKET")
    if socket_path:
        serve(socket_path)
    else:
        sys.exit(realise_one(sys.argv[1:]))
