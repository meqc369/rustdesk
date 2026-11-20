//! Qianchen Desk: mute the controlled Windows computer's speakers while a controller listens.
//! The mute belongs to one connection; the previous state comes back when it unmutes or leaves.
use hbb_common::log;
use std::sync::Mutex;
use windows::Win32::{
    Media::Audio::{eConsole, eRender, Endpoints::IAudioEndpointVolume, IMMDeviceEnumerator, MMDeviceEnumerator},
    System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_ALL, COINIT_MULTITHREADED},
};

/// (connection id, whether the speakers were already muted before)
static MUTED_BY: Mutex<Option<(i32, bool)>> = Mutex::new(None);

fn endpoint() -> windows::core::Result<IAudioEndpointVolume> {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        let en: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)?;
        let dev = en.GetDefaultAudioEndpoint(eRender, eConsole)?;
        dev.Activate::<IAudioEndpointVolume>(CLSCTX_ALL, None)
    }
}

pub fn set_speaker_mute(conn: i32, on: bool) {
    let mut g = MUTED_BY.lock().unwrap();
    let res = (|| -> windows::core::Result<()> {
        if on {
            if g.is_some() {
                return Ok(());
            }
            let ep = endpoint()?;
            let before = unsafe { ep.GetMute()?.as_bool() };
            unsafe { ep.SetMute(true, std::ptr::null())? };
            *g = Some((conn, before));
        } else if let Some((c, before)) = *g {
            if c != conn {
                return Ok(());
            }
            *g = None;
            unsafe { endpoint()?.SetMute(before, std::ptr::null())? };
        }
        Ok(())
    })();
    match res {
        Ok(()) => log::info!("speaker mute {} by conn {}", on, conn),
        Err(e) => log::warn!("speaker mute {}: {}", on, e),
    }
}
