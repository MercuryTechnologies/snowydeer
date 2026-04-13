// SPDX-FileCopyrightText: 2026 Mercury Technologies, Inc.
//
// SPDX-License-Identifier: MIT OR Apache-2.0

//! This is obsolete since we added support for this exact operation to the Lix
//! CLI in 2.95: <https://gerrit.lix.systems/c/lix/+/5205>
//!
//! We're still shipping this until we can run Lix 2.95 everywhere.
//!
//! A simple tool to deal with `nix-store --import` not supporting importing CA
//! paths (bleh!) and requiring trusted user to execute (bleh!) because of not
//! supporting CA paths, while none of the rest of the nix CLI supports
//! importing paths with references because I guess nobody wanted it before us.
//!
//! This connects directly to the nix daemon and does the thing we want.

use std::collections::BTreeSet;
use std::fmt::Write as _;
use std::io::BufRead;
use std::io::BufReader;
use std::io::Read;
use std::io::Write;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;

use clap::Parser;
use hex_pp::HexPP;
use miette::IntoDiagnostic;
use miette::WrapErr;
use miette::miette;
use nix_remote::StorePathSet;
use nix_remote::StringSet;
use nix_remote::nix_client::NixDaemonClient;
use nix_remote::stderr::Msg;
use nix_remote::worker_op::Resp;
use nix_remote::worker_op::WithFramedSource;
use nix_remote::worker_op::WorkerOp;
use nix_remote::{NixString, StorePath, worker_op::AddToStoreNar};
use sha2::Digest;
use sha2::Sha256;
use tracing::level_filters::LevelFilter;
use tracing_subscriber::EnvFilter;

#[derive(clap::Parser)]
struct Args {
    /// File containing the references to use.
    #[clap(long)]
    references_file: PathBuf,
    /// NAR file with the contents we want to send to the Nix daemon.
    #[clap(long)]
    nar_file: PathBuf,
    /// Name to use for the added store path
    #[clap(long)]
    name: String,
}

struct LoggingConnectionWrapperRead<Inner> {
    read: BufReader<Inner>,
}

struct LoggingConnectionWrapperWrite<Inner> {
    write: Inner,
}

impl<Inner: Read> LoggingConnectionWrapperRead<Inner> {
    pub fn new(inner: Inner) -> Self {
        Self {
            read: BufReader::new(inner),
        }
    }
}
impl<Inner> LoggingConnectionWrapperWrite<Inner> {
    pub fn new(inner: Inner) -> Self {
        Self { write: inner }
    }
}

impl<Inner: Read> Read for LoggingConnectionWrapperRead<Inner> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let result = self.read.read(buf);
        if let Ok(bytes) = result {
            tracing::debug!(
                received = ?(&&buf[..bytes]).hex_dump(),
                "received bytes from server"
            );
        }
        result
    }
}

impl<Inner: Read> BufRead for LoggingConnectionWrapperRead<Inner> {
    fn fill_buf(&mut self) -> std::io::Result<&[u8]> {
        self.read.fill_buf()
    }

    fn consume(&mut self, amount: usize) {
        self.read.consume(amount)
    }
}

impl<Inner: Write> Write for LoggingConnectionWrapperWrite<Inner> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let result = self.write.write(buf);
        if let Ok(bytes) = result {
            tracing::debug!(sent = ?(&&buf[..bytes]).hex_dump(), "sent bytes to server");
        }
        result
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.write.flush()
    }
}

fn connect_to_nix_daemon() -> miette::Result<UnixStream> {
    let path = std::env::var("NIX_DAEMON_SOCKET_PATH")
        .unwrap_or_else(|_| "/nix/var/nix/daemon-socket/socket".to_owned());

    let sock = UnixStream::connect(path)
        .into_diagnostic()
        .wrap_err("connect()")?;
    sock.set_nonblocking(false).into_diagnostic()?;
    Ok(sock)
}

/// Basename means: `sgdfkljhsgdfhlkdfg-namenamename-1.2.3`
#[derive(Debug, Clone, PartialOrd, Ord, PartialEq, Eq)]
struct BaseName(String);

impl BaseName {
    fn from_abs_path(p: &str) -> BaseName {
        BaseName(
            p.strip_prefix("/nix/store/")
                .expect("store path not starting with /nix/store, jacked")
                .to_owned(),
        )
    }
}

impl std::fmt::Display for BaseName {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "/nix/store/{}", &self.0)
    }
}

impl From<BaseName> for StorePath {
    fn from(value: BaseName) -> Self {
        StorePath(format!("/nix/store/{}", value.0).into_bytes().into())
    }
}

/// <https://git.lix.systems/lix-project/lix/src/32cfbe395903890a9df104cbc4c0474033363f13/lix/libstore/store-api.cc#L80-L170>
///
/// ```text
/// source:abcde-somepath:bcdef-someother:sha256:abcdef1234:/nix/store:foo.tar.gz
/// ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ ^^^^^^^^^^^^^^^^^ ^^^^^^^^^^ ^^^^^^^^^^
///  makeType                             NAR hash base16   storeDir     name
///  for CA: type=source
///  :-separated references
/// ```
///
/// Hash with sha256 then "compress" the hash: XOR the extra bytes down to 160
/// bits, then base32 encode to get the hash part.
///
/// We hit the case here:
///
/// ```c++
/// StorePath Store::makeFixedOutputPath(std::string_view name, const FixedOutputInfo & info) const
/// {
///     if (info.hash.type == HashType::SHA256 && info.method == FileIngestionMethod::Recursive) {
///         return makeStorePath(makeType(*this, "source", info.references), info.hash, name);
///     } else {
/// ```
#[derive(Debug)]
struct StorePathHasher {
    references: BTreeSet<BaseName>,
    nar_hash: Sha256,
    name: String,
}

/// "Compresses" a hash until it becomes a store path; required to turn a
/// sha256 into a sha1 sized thing.
///
/// <https://git.lix.systems/lix-project/lix/src/32cfbe395903890a9df104cbc4c0474033363f13/lix/libstore/store-api.cc#L165-L169>
///
/// Lix implementation: <https://git.lix.systems/lix-project/lix/src/7d681a50493b7d5fd1359adc756006ad60d65640/lix/libutil/hash.cc#L371-L378>
fn compress_hash(hash: &[u8], len: usize) -> Vec<u8> {
    let mut out = vec![0; len];
    for (i, el) in hash.iter().enumerate() {
        out[i % len] ^= *el;
    }
    out
}

impl StorePathHasher {
    #[tracing::instrument(ret)]
    fn to_hashable(&self) -> String {
        let mut out = String::new();
        write!(&mut out, "source").unwrap();
        for reference in &self.references {
            write!(&mut out, ":/nix/store/{}", reference.0).unwrap();
        }
        let nar_hash = hex::encode(self.nar_hash.clone().finalize());
        write!(
            &mut out,
            ":sha256:{nar_hash}:/nix/store:{name}",
            name = self.name
        )
        .unwrap();
        out
    }

    fn to_basename(&self) -> BaseName {
        let mut hasher = Sha256::new();
        hasher.write_all(self.to_hashable().as_bytes()).unwrap();
        let hash = hasher.finalize();

        // 160 bits (sha1)
        let compressed = compress_hash(&hash, 20);
        // This happens to be a nix base32 implementation we can use
        let encoded = std::str::from_utf8(&nix_remote::NarHash::from_bytes(&compressed).data)
            .unwrap()
            .to_owned();

        BaseName(format!("{encoded}-{name}", name = self.name))
    }
}

fn main() -> miette::Result<()> {
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            EnvFilter::builder()
                .with_default_directive(LevelFilter::INFO.into())
                .from_env()
                .into_diagnostic()
                .wrap_err("Parsing tracing env filter")?,
        )
        .init();
    let args = Args::parse();

    let mut nar_contents = Vec::new();
    std::fs::File::open(args.nar_file)
        .into_diagnostic()
        .wrap_err("Failed opening NAR")?
        .read_to_end(&mut nar_contents)
        .into_diagnostic()
        .wrap_err("Failed to read file contents")?;

    let references: BTreeSet<BaseName> = std::fs::read_to_string(args.references_file)
        .into_diagnostic()
        .wrap_err("Reading references file")?
        .lines()
        .filter(|s| !s.is_empty())
        .map(BaseName::from_abs_path)
        .collect();

    let sock = connect_to_nix_daemon().wrap_err("Connecting to Nix daemon")?;
    let wrapper_r = LoggingConnectionWrapperRead::new(&sock);
    let wrapper_w = LoggingConnectionWrapperWrite::new(&sock);
    // FIXME(jade): support using this proxy for debugging more deliberately
    // let mut child = std::process::Command::new("nix-daemon")
    //     .arg("--stdio")
    //     .stdin(std::process::Stdio::piped())
    //     .stdout(std::process::Stdio::piped())
    //     .spawn()
    //     .unwrap();
    // let wrapper_r = LoggingConnectionWrapperRead::new(child.stdout.take().unwrap());
    // let wrapper_w = LoggingConnectionWrapperWrite::new(child.stdin.take().unwrap());

    let mut connection = NixDaemonClient::new(wrapper_r, wrapper_w).into_diagnostic()?;

    let mut hasher = sha2::Sha256::default();
    hasher.write_all(&nar_contents).unwrap();
    let nar_hash = hex::encode(hasher.clone().finalize());

    let store_path = StorePathHasher {
        references: references.clone(),
        nar_hash: hasher,
        name: args.name,
    };
    let store_path = store_path.to_basename();

    // Fun cursed fact: Nix puts base32 in content_address, but it passes it
    // into a function that accepts base16 too. Just for fun. Totally untested
    // code path too. Awesome for me because I don't want to write a nix base32
    // encoder.
    //
    // https://github.com/andreasots/base32/issues/31
    let mut ca_string = b"fixed:r:sha256:".to_vec();
    ca_string.extend_from_slice(nar_hash.as_bytes());

    let message = AddToStoreNar {
        path: store_path.clone().into(),
        deriver: StorePath(NixString::from_bytes(b"")),
        nar_hash: NixString(nar_hash.into_bytes().into()),
        nar_size: nar_contents.len() as u64,
        references: StorePathSet {
            paths: references.iter().cloned().map(StorePath::from).collect(),
        },
        registration_time: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs(),
        ultimate: true,
        sigs: StringSet { paths: Vec::new() },
        content_address: NixString(ca_string.into()),
        repair: false,
        dont_check_sigs: false,
    };

    let resp_marker = Resp::default();
    let op = WorkerOp::AddToStoreNar(WithFramedSource(message), resp_marker);

    connection
        .send_worker_op_to_daemon(&op)
        .into_diagnostic()
        .wrap_err("send worker op")?;

    // Some operations have non-framed NARs (awful protocol design!!!!) but
    // this one is reasonable, which means that nar::stream is inapplicable.
    for chunk in nar_contents.chunks(4096) {
        connection
            .streaming_write_len(chunk.len() as u64)
            .into_diagnostic()?;
        // due to bad API design, this takes a separate length
        connection
            .streaming_write_buff(chunk, chunk.len())
            .into_diagnostic()?;
    }
    // Framed writers end in a zero length chunk
    connection.streaming_write_len(0).into_diagnostic()?;

    connection.flush().into_diagnostic()?;

    tracing::info!(store_path = %store_path, "wrote nar!");

    while let Some(msg) = connection.read_error_msg_or_eof().into_diagnostic()? {
        match msg {
            Msg::Last(()) => {
                break;
            }
            Msg::Write(e) => {
                tracing::info!(write = ?e);
            }
            Msg::StartActivity(_) | Msg::StopActivity(_) | Msg::Result(_) => {}
            Msg::Next(e) => {
                tracing::info!(next = ?e);
            }
            Msg::Error(e) => {
                return Err(miette!("Nix error: {}", e.message));
            }
        }
    }

    connection
        .read_build_response_from_daemon(&resp_marker)
        .into_diagnostic()?;

    println!("{}", store_path);

    Ok(())
}
