//! Socket-level suites over raw loopback TCP: SSE flush latency, consumer
//! backpressure propagation, and the negotiated HTTP/WebSocket posture.

mod backpressure;
mod protocol;
mod stream_latency;
