//! SSE event framing (plan §15.4): each event is assembled into one
//! contiguous [`Bytes`] frame — `data: ` prefix, payload, `\n\n` terminator
//! — with a single exact-size allocation and no intermediate `String`s. The
//! HTTP body stream then hands each frame to hyper for a vectored write.

use bytes::{BufMut, Bytes, BytesMut};

pub const DATA_PREFIX: &[u8] = b"data: ";
pub const EVENT_END: &[u8] = b"\n\n";

/// The exact chat-completions stream terminator (Go: `data: [DONE]\n\n`).
pub const DONE_EVENT: &[u8] = b"data: [DONE]\n\n";

/// Frames one payload as an SSE event.
pub fn event(payload: &[u8]) -> Bytes {
    let mut buf = BytesMut::with_capacity(DATA_PREFIX.len() + payload.len() + EVENT_END.len());
    buf.put_slice(DATA_PREFIX);
    buf.put_slice(payload);
    buf.put_slice(EVENT_END);
    buf.freeze()
}

/// Frames an already-complete SSE line (sealed transport emits full
/// `data: <b64>\n\n` lines itself).
pub fn raw(line: String) -> Bytes {
    Bytes::from(line)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_shape() {
        assert_eq!(&event(b"{\"a\":1}")[..], b"data: {\"a\":1}\n\n");
        assert_eq!(DONE_EVENT, b"data: [DONE]\n\n");
    }
}
