//! Qianchen Desk: CPU, memory, network and temperature of this computer. Sent with the
//! heartbeat so the device panel on other computers can show them.
use hbb_common::sysinfo::{Components, Disks, Networks, System};
use serde_json::{json, Value};
use std::{
    sync::Mutex,
    time::{Duration, Instant},
};

struct State {
    sys: System,
    nets: Networks,
    nets_listed: Instant,
    comps: Components,
    disks: Disks,
    last: Option<(Instant, u64, u64)>,
}

lazy_static::lazy_static! {
    static ref STATE: Mutex<Option<State>> = Mutex::new(None);
}

/// Physical adapters only: VPN tunnels and virtual switches would count the same bytes twice.
fn counted(name: &str) -> bool {
    let n = name.to_lowercase();
    n != "lo"
        && ![
            "loopback", "lo0", "utun", "tun", "tap", "meta", "clash", "vethernet", "virtual",
            "vmware", "docker", "bridge", "awdl", "llw", "anpi", "gif", "stf",
        ]
        .iter()
        .any(|k| n.contains(k))
}

fn round1(x: f64) -> f64 {
    (x * 10.).round() / 10.
}

/// `{cpu %, mem bytes, mem_total bytes, rx B/s, tx B/s, temp °C or null}`; rates and CPU
/// are averages since the previous call.
pub fn snapshot() -> Value {
    let mut guard = STATE.lock().unwrap();
    let st = guard.get_or_insert_with(|| {
        let mut sys = System::new();
        sys.refresh_cpu_usage();
        State {
            sys,
            nets: Networks::new_with_refreshed_list(),
            nets_listed: Instant::now(),
            comps: Components::new_with_refreshed_list(),
            disks: Disks::new_with_refreshed_list(),
            last: None,
        }
    });
    st.sys.refresh_cpu_usage();
    st.sys.refresh_memory();
    if st.nets_listed.elapsed() > Duration::from_secs(300) {
        st.nets.refresh_list();
        st.nets_listed = Instant::now();
    } else {
        st.nets.refresh();
    }
    st.comps.refresh();
    st.disks.refresh();
    // System drive: C: on Windows, the data volume on macOS.
    let sys_mount = if cfg!(windows) {
        format!("{}\\", std::env::var("SystemDrive").unwrap_or_else(|_| "C:".to_owned()))
    } else {
        "/System/Volumes/Data".to_owned()
    };
    let disk = st
        .disks
        .iter()
        .find(|d| d.mount_point().to_string_lossy().eq_ignore_ascii_case(&sys_mount))
        .or_else(|| st.disks.iter().find(|d| d.mount_point() == std::path::Path::new("/")))
        .map(|d| (d.available_space(), d.total_space()));
    let (rx, tx) = st
        .nets
        .iter()
        .filter(|(name, _)| counted(name))
        .fold((0u64, 0u64), |(r, t), (_, d)| {
            (r + d.total_received(), t + d.total_transmitted())
        });
    let now = Instant::now();
    let (rx_s, tx_s) = match st.last {
        Some((t, r, x)) => {
            let secs = now.duration_since(t).as_secs_f64().max(0.5);
            (
                (rx.saturating_sub(r) as f64 / secs) as u64,
                (tx.saturating_sub(x) as f64 / secs) as u64,
            )
        }
        None => (0, 0),
    };
    st.last = Some((now, rx, tx));
    let temp = st
        .comps
        .iter()
        .map(|c| c.temperature())
        .filter(|t| t.is_finite() && *t > 5. && *t < 125.)
        .fold(None, |m: Option<f32>, t| Some(m.map_or(t, |m| m.max(t))));
    json!({
        "cpu": round1(st.sys.global_cpu_info().cpu_usage() as f64),
        "mem": st.sys.used_memory(),
        "mem_total": st.sys.total_memory(),
        "rx": rx_s,
        "tx": tx_s,
        "temp": temp.map(|t| round1(t as f64)),
        "disk_free": disk.map(|d| d.0),
        "disk_total": disk.map(|d| d.1),
    })
}
