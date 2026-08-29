//! Full-stack end-to-end suites: real Postgres + the real bootstrap app
//! with fake providers, proving money trails for settlement, rejection,
//! and cancellation.

mod cancellation;
mod rejections;
mod v1_settlement;
mod v2_settlement;
