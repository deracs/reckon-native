mod akahu_bank_data;
mod akahu_wire;
mod backend_handshake;
mod bank_calendar;
mod bank_derivations;
mod bank_models;
mod native_bank_server;

use akahu_bank_data::AkahuBankData;
use backend_handshake::BackendHandshake;
use hyper::{server::conn::http1, service::service_fn};
use hyper_util::rt::TokioIo;
use std::{
    io::{BufRead, Read, Write},
    sync::Arc,
    time::Duration,
};
use tokio::{
    net::TcpListener,
    signal::unix::{SignalKind, signal},
    sync::oneshot,
};

#[tokio::main(flavor = "current_thread")]
async fn main() {
    // This is the only protocol output. Panic diagnostics cannot include bank records.
    std::panic::set_hook(Box::new(|_| {}));
    let (handshake_send, handshake_read) = oneshot::channel();
    let (closed_send, mut closed_read) = oneshot::channel();
    // A dedicated stdin watcher can be abandoned without holding Tokio's blocking pool open.
    std::thread::spawn(move || {
        let stdin = std::io::stdin();
        let mut input = stdin.lock();
        let mut raw = Vec::new();
        let read = input.by_ref().take(32769).read_until(b'\n', &mut raw);
        let parsed = if read.is_ok() && raw.len() <= 32768 && raw.last() == Some(&b'\n') {
            BackendHandshake::parse_handshake(&raw)
        } else {
            Err(())
        };
        let _ = handshake_send.send(parsed);
        let _ = std::io::copy(&mut input, &mut std::io::sink());
        let _ = closed_send.send(());
    });
    let Ok(mut terminate) = signal(SignalKind::terminate()) else {
        fail_startup();
    };
    let Ok(mut interrupt) = signal(SignalKind::interrupt()) else {
        fail_startup();
    };
    let parent = unsafe { libc::getppid() };
    let parent_exit = async {
        loop {
            tokio::time::sleep(Duration::from_secs(1)).await;
            let now = unsafe { libc::getppid() };
            if now == 1 || now != parent {
                return;
            }
        }
    };
    let program = async {
        let handshake = match tokio::time::timeout(Duration::from_secs(10), handshake_read).await {
            Ok(Ok(Ok(handshake))) => handshake,
            _ => fail_startup(),
        };
        let bank = match AkahuBankData::new(&handshake) {
            Ok(bank) => Arc::new(bank),
            Err(_) => fail_startup(),
        };
        let listener = match TcpListener::bind("127.0.0.1:0").await {
            Ok(listener) => listener,
            Err(_) => fail_startup(),
        };
        let port = match listener.local_addr() {
            Ok(address) => address.port(),
            Err(_) => fail_startup(),
        };
        let token = Arc::new(handshake.api_token);
        println!("{{\"event\":\"ready\",\"port\":{port}}}");
        let _ = std::io::stdout().flush();
        loop {
            let Ok((stream, _)) = listener.accept().await else {
                return;
            };
            let bank = bank.clone();
            let token = token.clone();
            tokio::task::spawn_local(async move {
                let service = service_fn(|request| {
                    native_bank_server::serve_bank_request(request, port, &token, &bank)
                });
                // HTTP/1's default half-close behavior drops the request on disconnect, cancelling upstream I/O.
                let _ = http1::Builder::new()
                    .max_buf_size(32768)
                    .serve_connection(TokioIo::new(stream), service)
                    .await;
            });
        }
    };
    tokio::task::LocalSet::new().run_until(async {
        tokio::select! { _ = program => {},_ = &mut closed_read => {},_ = parent_exit => {},_ = terminate.recv() => {},_ = interrupt.recv() => {} }
    }).await;
    // Returning drops all request tasks, source connections, caches and the local listener.
}
fn fail_startup() -> ! {
    println!("{{\"event\":\"failed\"}}");
    let _ = std::io::stdout().flush();
    std::process::exit(1)
}
