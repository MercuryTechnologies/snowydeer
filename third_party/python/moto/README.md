<!--
SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc

SPDX-License-Identifier: MIT OR Apache-2.0
-->

# moto

Mock AWS API server written in Python, for use in testing.

Elsewhere, we use `localstack` for this, which requires Docker (which is rather slow and has limited benefit).

Docs: <https://docs.getmoto.org/>
Code: <https://github.com/getmoto/moto>

# Setup for awscli

1. `buck run //third_party/python/moto:moto_server -- --port 5001`
2. Dump this stuff in `~/.aws/config`:

```
[services moto]
s3 =
  endpoint_url = http://localhost:5001
[profile moto]
region = us-east-1
services = moto
aws_access_key_id = test
aws_secret_access_key = test
aws_security_token = test
aws_session_token = test
```

3. `export AWS_PROFILE=moto`
4. You can now mess around with fake S3:

```
$ aws s3api create-bucket --bucket foo
$ aws s3 cp README.md s3://foo/README.md
```

# Gotchas

Default port is `5000` and `localhost:5000` is AirPlay on macOS, so you can get utterly incomprehensible errors sometimes.
Use `buck run //third_party/python/moto:moto_server -- --port 5001` or similar instead.

General port snafus: don't hardcode the port to use in tests, since they may conflict with each other; the correct way to do this is to try 5 times to pick random ports between 10000 and 65535 and retry if it fails to bind the port.
Alas aws doesn't support HTTP over Unix socket, which fixes this much better.
