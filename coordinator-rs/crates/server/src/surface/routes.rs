use std::sync::OnceLock;

use axum::http::Method;
use serde::{Deserialize, Serialize};

const ROUTE_CONTRACT: &str = include_str!("../../../../../tests/contracts/http/routes.json");

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct RegisteredRoute {
    pub pattern: String,
    pub method: String,
    pub path: String,
    pub handler: String,
    pub auth: String,
    pub area: String,
    pub side_effects: String,
    pub rust_owner: String,
    pub pilot: bool,
    pub disposition: String,
}

#[derive(Deserialize)]
struct RouteContract {
    schema_version: u32,
    routes: Vec<RegisteredRoute>,
}

static ROUTES: OnceLock<Vec<RegisteredRoute>> = OnceLock::new();

/// Returns the committed route contract used by the composition root. A
/// startup binary embeds this finite inventory, so the admin endpoint never
/// scrapes source files or consults the retired Go process.
#[must_use]
pub fn registered_routes() -> &'static [RegisteredRoute] {
    ROUTES.get_or_init(|| {
        let contract: RouteContract =
            serde_json::from_str(ROUTE_CONTRACT).expect("committed route inventory must be valid");
        assert_eq!(
            contract.schema_version, 1,
            "unsupported route inventory schema"
        );
        contract.routes
    })
}

#[must_use]
pub(crate) fn registered_route(method: &Method, path: &str) -> Option<&'static RegisteredRoute> {
    registered_routes()
        .iter()
        .filter(|route| {
            route.method != "ANY"
                && route.method == method.as_str()
                && route_path_matches(&route.path, path)
        })
        .max_by_key(|route| route_priority(&route.path))
}

#[must_use]
pub(crate) fn is_registered_path(path: &str) -> bool {
    registered_routes()
        .iter()
        .any(|route| route.method != "ANY" && route_path_matches(&route.path, path))
}

#[must_use]
pub(crate) fn is_registered_mutation(method: &Method, path: &str) -> bool {
    registered_route(method, path).is_some_and(|route| {
        matches!(
            route.side_effects.as_str(),
            "write" | "external_event" | "live_session"
        )
    })
}

fn route_path_matches(pattern: &str, path: &str) -> bool {
    let Some(parameter_start) = pattern.find('{') else {
        if prefix_contract(pattern) {
            return path
                .strip_prefix(pattern)
                .is_some_and(|suffix| !suffix.is_empty());
        }
        return pattern == path;
    };
    let prefix = &pattern[..parameter_start];
    let Some(suffix) = path.strip_prefix(prefix) else {
        return false;
    };
    if pattern[parameter_start..].contains("...}") {
        !suffix.is_empty()
    } else {
        !suffix.is_empty() && !suffix.contains('/')
    }
}

fn prefix_contract(pattern: &str) -> bool {
    matches!(
        pattern,
        "/v1/models/catalog/manifest/" | "/v1/models/catalog/" | "/v1/admin/models/"
    )
}

fn route_priority(pattern: &str) -> (u8, usize) {
    let static_length = pattern.find('{').unwrap_or(pattern.len());
    if !pattern.contains('{') && !prefix_contract(pattern) {
        (3, static_length)
    } else if pattern.contains('{') && !pattern.contains("...}") {
        (2, static_length)
    } else {
        (1, static_length)
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use super::{ROUTE_CONTRACT, RouteContract};

    const ROUTER_SOURCES: &[&str] = &[
        include_str!("../app.rs"),
        include_str!("../http/mod.rs"),
        include_str!("http.rs"),
        include_str!("identity/routes.rs"),
        include_str!("billing/mod.rs"),
        include_str!("operations/mod.rs"),
    ];

    #[test]
    fn committed_inventory_matches_every_rust_route_declaration() {
        let contract: RouteContract =
            serde_json::from_str(ROUTE_CONTRACT).expect("route contract JSON");
        let expected = contract
            .routes
            .iter()
            .map(|route| (route.method.clone(), canonical_path(&route.path)))
            .collect::<BTreeSet<_>>();
        assert_eq!(
            expected.len(),
            contract.routes.len(),
            "route contract contains duplicate method/path entries"
        );

        let mut declared = BTreeSet::new();
        for source in ROUTER_SOURCES {
            declared.extend(declared_routes(source));
        }
        declared.insert(("ANY".to_owned(), "/v1/{*}".to_owned()));

        assert_eq!(
            declared, expected,
            "Rust route declarations and the machine-readable contract diverged"
        );
    }

    #[test]
    fn route_inventory_has_exact_known_auth_classes() {
        let contract: RouteContract =
            serde_json::from_str(ROUTE_CONTRACT).expect("route contract JSON");
        let allowed = [
            "public",
            "provider_registration",
            "privy_jwt",
            "api_key_or_privy",
            "mdm_command_and_secret",
            "stripe_signature",
            "release_key",
            "admin_key_only",
            "admin_key_or_privy_admin",
            "publishing_key_or_admin_key",
            "optional_provider_token_privy_api_key_or_anonymous",
        ];
        for route in contract.routes {
            assert!(
                allowed.contains(&route.auth.as_str()),
                "{} {} has unknown auth class {:?}",
                route.method,
                route.path,
                route.auth
            );
        }
    }

    #[test]
    fn every_contract_route_has_a_local_rust_owner() {
        let contract: RouteContract =
            serde_json::from_str(ROUTE_CONTRACT).expect("route contract JSON");
        for route in contract.routes {
            assert_eq!(
                route.disposition, "implement",
                "{} {} is not locally implemented",
                route.method, route.path
            );
            if route.method == "ANY" {
                assert_eq!(route.rust_owner, "compatibility catch-all");
                continue;
            }
            assert!(
                matches!(
                    route.rust_owner.as_str(),
                    "pilot adapter" | "full-surface adapter"
                ),
                "{} {} has non-local owner {:?}",
                route.method,
                route.path,
                route.rust_owner
            );
        }
    }

    fn declared_routes(source: &str) -> BTreeSet<(String, String)> {
        let mut routes = BTreeSet::new();
        let mut offset = 0;
        while let Some(relative) = source[offset..].find(".route(") {
            let open = offset + relative + ".route".len();
            let Some(close) = matching_parenthesis(source, open) else {
                panic!("unbalanced .route call");
            };
            let call = &source[open + 1..close];
            let path = first_string(call).expect("route path must be a string literal");
            for (needle, method) in [
                ("get(", "GET"),
                ("post(", "POST"),
                ("put(", "PUT"),
                ("patch(", "PATCH"),
                ("delete(", "DELETE"),
            ] {
                if call.contains(needle) {
                    routes.insert((method.to_owned(), canonical_path(path)));
                }
            }
            offset = close + 1;
        }
        routes
    }

    fn matching_parenthesis(source: &str, open: usize) -> Option<usize> {
        debug_assert_eq!(source.as_bytes().get(open), Some(&b'('));
        let mut depth = 0_u32;
        let mut quoted = false;
        let mut escaped = false;
        for (relative, byte) in source.as_bytes()[open..].iter().copied().enumerate() {
            if quoted {
                if escaped {
                    escaped = false;
                } else if byte == b'\\' {
                    escaped = true;
                } else if byte == b'"' {
                    quoted = false;
                }
                continue;
            }
            match byte {
                b'"' => quoted = true,
                b'(' => depth += 1,
                b')' => {
                    depth -= 1;
                    if depth == 0 {
                        return Some(open + relative);
                    }
                }
                _ => {}
            }
        }
        None
    }

    fn first_string(call: &str) -> Option<&str> {
        let start = call.find('"')? + 1;
        let end = call[start..].find('"')? + start;
        Some(&call[start..end])
    }

    fn canonical_path(path: &str) -> String {
        if path == "/v1/" {
            return "/v1/{*}".to_owned();
        }
        if matches!(
            path,
            "/v1/models/catalog/manifest/" | "/v1/models/catalog/" | "/v1/admin/models/"
        ) {
            return format!("{path}{{*}}");
        }
        let Some(start) = path.find('{') else {
            return path.to_owned();
        };
        let end = path[start..]
            .find('}')
            .map(|relative| start + relative)
            .expect("route parameter closes");
        let wildcard = path[start..=end].contains("...") || path[start..=end].starts_with("{*");
        format!(
            "{}{}{}",
            &path[..start],
            if wildcard { "{*}" } else { "{}" },
            &path[end + 1..]
        )
    }
}
