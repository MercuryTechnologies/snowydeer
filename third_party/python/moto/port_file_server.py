# SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc
#
# SPDX-License-Identifier: MIT OR Apache-2.0

"""
Port file server for moto mocks, to bind an ephemeral port and communicate it
to the caller in a maximally correct way.

Format details: https://docs.rs/port-file/latest/port_file/
"""

import argparse
import os
import tempfile
from werkzeug.serving import make_server
from moto.moto_server.werkzeug_app import (
    DomainDispatcherApplication,
    create_backend_app,
)

ap = argparse.ArgumentParser()
ap.add_argument("--port-file", required=True)
ap.add_argument("-H", "--host", default="127.0.0.1")
args = ap.parse_args()

srv = make_server(
    args.host, 0, DomainDispatcherApplication(create_backend_app), threaded=True
)
port = srv.socket.getsockname()[1]

# Atomic publish: write to a temp file then rename, matching port-file's format
# (decimal port number followed by a single newline).
d = os.path.dirname(args.port_file) or "."
fd, tmp = tempfile.mkstemp(dir=d)
os.write(fd, (str(port) + "\n").encode())
os.close(fd)
os.replace(tmp, args.port_file)

srv.serve_forever()
