//! Qianchen Desk: power actions from the device list without opening a session.
//! They log in with the password saved for the peer (or the address book one),
//! send one request and disconnect.

use std::sync::{Arc, Mutex, RwLock};

use async_trait::async_trait;
use base::message_proto::*;
use hbb_common::{
    config::{LocalConfig, READ_TIMEOUT},
    futures::StreamExt,
    log,
    protobuf::Message as _,
    rendezvous_proto::ConnType,
    timeout, tokio, Stream,
};

use crate::client::*;

#[derive(Clone)]
struct Headless {
    lc: Arc<RwLock<LoginConfigHandler>>,
    error: Arc<Mutex<Option<String>>>,
}

impl Headless {
    fn fail(&self, err: &str) {
        let mut e = self.error.lock().unwrap();
        if e.is_none() {
            *e = Some(err.to_owned());
        }
    }

    fn take_error(&self) -> Option<String> {
        self.error.lock().unwrap().take()
    }
}

#[async_trait]
impl Interface for Headless {
    fn send(&self, _data: Data) {}

    fn msgbox(&self, msgtype: &str, title: &str, text: &str, _link: &str) {
        if msgtype == "input-password" {
            self.fail("Password Required");
        } else if msgtype.contains("error") || msgtype.starts_with("wait-remote-accept") {
            self.fail(if text.is_empty() { title } else { text });
        }
    }

    fn handle_login_error(&self, err: &str) -> bool {
        self.fail(err);
        false
    }

    fn handle_peer_info(&self, _pi: PeerInfo) {}

    fn set_multiple_windows_session(&self, _sessions: Vec<WindowsSession>) {}

    async fn handle_hash(
        &self,
        pass: &str,
        hash: Hash,
        trust: &mut crate::trusted_devices::client::Session,
        peer: &mut Stream,
    ) -> bool {
        crate::client::handle_hash(self.lc.clone(), pass, hash, self, trust, peer).await
    }

    async fn handle_login_from_ui(
        &self,
        os_username: String,
        os_password: String,
        password: String,
        remember: bool,
        trust: &mut crate::trusted_devices::client::Session,
        peer: &mut Stream,
    ) {
        if let Err(e) = crate::client::handle_login_from_ui(
            self.lc.clone(),
            os_username,
            os_password,
            password,
            remember,
            trust,
            peer,
        )
        .await
        {
            self.fail(&e.to_string());
        }
    }

    async fn handle_test_delay(&self, t: TestDelay, peer: &mut Stream) {
        crate::client::handle_test_delay(t, peer).await;
    }

    fn get_lch(&self) -> Arc<RwLock<LoginConfigHandler>> {
        self.lc.clone()
    }
}

/// Returns "" on success, otherwise an untranslated error message.
pub async fn shutdown_peer(id: String) -> String {
    let mut misc = Misc::new();
    misc.set_shutdown_remote_device(true);
    result(send_misc(id, misc).await)
}

/// Returns "" on success, otherwise an untranslated error message.
pub async fn restart_peer(id: String) -> String {
    let mut misc = Misc::new();
    misc.set_restart_remote_device(true);
    result(send_misc(id, misc).await)
}

/// Returns "" on success, otherwise an untranslated error message.
pub async fn lock_peer(id: String) -> String {
    let mut msg = Message::new();
    msg.set_key_event(crate::keyboard::client::event_lock_screen());
    result(send_message(id, msg).await)
}

/// Wake `id` up through another device on the same LAN that is still online.
/// Candidates are devices that reported MACs, i.e. run Qianchen Desk; most recent first.
/// Returns "" on success, otherwise an untranslated error message.
pub async fn wake_peer(id: String) -> String {
    let peers = hbb_common::config::PeerConfig::peers(None);
    let macs = peers
        .iter()
        .find(|(x, _, _)| *x == id)
        .and_then(|(_, _, c)| c.options.get("qc-macs").cloned())
        .unwrap_or_default();
    if macs.is_empty() {
        return "wake-no-mac-tip".to_owned();
    }
    for (relay, _, _) in peers
        .iter()
        .filter(|(x, _, c)| *x != id && c.options.contains_key("qc-macs"))
        .take(5)
    {
        let mut misc = Misc::new();
        misc.set_qc_wake_on_lan(macs.clone());
        match send_misc(relay.clone(), misc).await {
            Ok(()) => {
                log::info!("Wake-on-LAN for {} sent through {}", id, relay);
                return "".to_owned();
            }
            Err(e) => log::info!("Relay {} for wake-on-LAN failed: {}", relay, e),
        }
    }
    "wake-no-relay-tip".to_owned()
}

fn result(r: Result<(), String>) -> String {
    match r {
        Ok(()) => "".to_owned(),
        Err(e) => e,
    }
}

async fn send_misc(id: String, misc: Misc) -> Result<(), String> {
    let mut msg = Message::new();
    msg.set_misc(misc);
    send_message(id, msg).await
}

/// Log in to `id` in the background, send one message and disconnect.
async fn send_message(id: String, msg_out: Message) -> Result<(), String> {
    let conn_type = ConnType::DEFAULT_CONN;
    let mut lc = LoginConfigHandler::default();
    lc.initialize(id.clone(), conn_type, None, false, None, None, None, "");
    let ui = Headless {
        lc: Arc::new(RwLock::new(lc)),
        error: Default::default(),
    };
    let key = crate::get_key(false).await;
    let token = LocalConfig::get_option("access_token");
    let ((mut stream, _direct, pk, _kcp, _stream_type), (feedback, rendezvous_server)) =
        Client::start(&id, &key, &token, conn_type, ui.clone())
            .await
            .map_err(|e| e.to_string())?;
    let _keep_it = hc_connection(feedback, rendezvous_server, &token).await;
    let mut trust = crate::trusted_devices::client::Session::new(
        &ui.lc.read().unwrap(),
        stream.is_secured(),
        pk.as_deref(),
    )
    .map_err(|e| e.to_string())?;

    loop {
        let bytes = match timeout(READ_TIMEOUT, stream.next()).await {
            Err(_) => return Err("Timeout".to_owned()),
            Ok(Some(Ok(bytes))) => bytes,
            Ok(Some(Err(e))) => return Err(e.to_string()),
            Ok(None) => return Err("Reset by the peer".to_owned()),
        };
        let msg_in = Message::parse_from_bytes(&bytes).map_err(|e| e.to_string())?;
        match msg_in.union {
            Some(message::Union::Hash(hash)) => {
                if !ui.handle_hash("", hash, &mut trust, &mut stream).await {
                    return Err(ui.take_error().unwrap_or("Connection Error".to_owned()));
                }
            }
            Some(message::Union::LoginResponse(lr)) => match trust.respond(lr, &ui).await.union {
                Some(login_response::Union::Error(err)) => return Err(err),
                Some(login_response::Union::PeerInfo(_)) => break,
                _ => {}
            },
            Some(message::Union::TestDelay(t)) => {
                ui.handle_test_delay(t, &mut stream).await;
            }
            _ => {}
        }
        if let Some(err) = ui.take_error() {
            return Err(err);
        }
    }

    let msg_out = trust.outgoing(msg_out);
    stream.send(&msg_out).await.map_err(|e| e.to_string())?;
    log::info!("Request sent to {}", id);
    // Give the peer a moment to read the request before the connection closes.
    tokio::time::sleep(std::time::Duration::from_millis(800)).await;
    Ok(())
}
