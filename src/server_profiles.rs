//! Client-side rendezvous server profiles.
//!
//! The service (controlled side) stays bound to exactly one rendezvous server, configured as
//! before via `custom-rendezvous-server` / `key` in the global `Config`. Profiles only affect
//! OUTGOING connections made by this client and are stored in the user's `LocalConfig`
//! (`RustDesk_local.toml`), which the service never reads.
//!
//! A profile is selected per connection by addressing the peer as `<id>@<profile>`,
//! e.g. `123456789@pwe` or `123456789/r@home`. It is expanded to RustDesk's existing
//! "other server" syntax `<id>@<host>?key=<key>` before the connection is set up, so every
//! session carries its own server and several sessions on different servers can run in
//! parallel.
//!
//! If the ID carries no `@` suffix, the profile in `default-server-profile` is applied (if set).
//! An empty default keeps the classic behaviour (use the service's server).

use hbb_common::{config::LocalConfig, log};
use serde::{Deserialize, Serialize};

/// `LocalConfig` key holding the JSON array of profiles.
pub const OPTION_SERVER_PROFILES: &str = "server-profiles";
/// `LocalConfig` key holding the name of the default profile for outgoing connections.
pub const OPTION_DEFAULT_SERVER_PROFILE: &str = "default-server-profile";

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct ServerProfile {
    /// Short identifier used in `<id>@<name>`; `[A-Za-z0-9_-]`, max 32 chars.
    pub name: String,
    /// ID (rendezvous) server, `host` or `host:port`.
    pub host: String,
    /// Public key of the hbbs (`id_ed25519.pub`). Empty only if the server doesn't enforce keys.
    pub key: String,
    /// Optional free text shown in the UI.
    pub description: String,
}

pub fn is_valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 32
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// Parse profiles from JSON; invalid entries are dropped, duplicate names keep the first one.
pub fn parse_profiles(json: &str) -> Vec<ServerProfile> {
    if json.trim().is_empty() {
        return Vec::new();
    }
    let raw: Vec<ServerProfile> = match serde_json::from_str(json) {
        Ok(v) => v,
        Err(e) => {
            log::error!("Invalid {}: {}", OPTION_SERVER_PROFILES, e);
            return Vec::new();
        }
    };
    let mut out: Vec<ServerProfile> = Vec::with_capacity(raw.len());
    for mut p in raw {
        p.name = p.name.trim().to_owned();
        p.host = p.host.trim().to_owned();
        p.key = p.key.trim().to_owned();
        if !is_valid_name(&p.name) || p.host.is_empty() {
            log::warn!("Ignoring invalid server profile {:?}", p.name);
            continue;
        }
        // the key is appended as a query argument, so it must not break the `id@host?key=` syntax
        if p.host.contains(['@', '?', '&', ' ']) || p.key.contains(['@', '?', '&', ' ']) {
            log::warn!("Ignoring server profile {:?}: invalid host or key", p.name);
            continue;
        }
        if out.iter().any(|x| x.name.eq_ignore_ascii_case(&p.name)) {
            continue;
        }
        out.push(p);
    }
    out
}

pub fn get_profiles() -> Vec<ServerProfile> {
    parse_profiles(&LocalConfig::get_option(OPTION_SERVER_PROFILES))
}

pub fn find_profile<'a>(profiles: &'a [ServerProfile], name: &str) -> Option<&'a ServerProfile> {
    profiles.iter().find(|p| p.name.eq_ignore_ascii_case(name))
}

/// Pure resolution logic, see [`resolve_id`].
///
/// Returns `(expanded_id, profile_name)`; `profile_name` is `Some` when a profile was applied.
pub fn resolve_id_with(
    id: &str,
    profiles: &[ServerProfile],
    default_profile: &str,
) -> (String, Option<String>) {
    let (raw_id, profile) = match id.split_once('@') {
        Some((raw_id, suffix)) => {
            // Explicit "other server" syntax (`id@host`, `id@host?key=..`, `id@public`)
            // is left untouched unless the suffix names a profile.
            if suffix.contains('?') {
                return (id.to_owned(), None);
            }
            match find_profile(profiles, suffix) {
                Some(p) => (raw_id, p),
                None => return (id.to_owned(), None),
            }
        }
        None => {
            if default_profile.is_empty() {
                return (id.to_owned(), None);
            }
            match find_profile(profiles, default_profile) {
                Some(p) => (id, p),
                None => {
                    log::warn!(
                        "Default server profile {:?} not found, using service server",
                        default_profile
                    );
                    return (id.to_owned(), None);
                }
            }
        }
    };
    let expanded = if profile.key.is_empty() {
        format!("{raw_id}@{}", profile.host)
    } else {
        format!("{raw_id}@{}?key={}", profile.host, profile.key)
    };
    (expanded, Some(profile.name.clone()))
}

/// Expand `<id>@<profile>` (or a plain `<id>` when a default profile is set) to
/// `<id>@<host>?key=<key>`. Anything else is returned unchanged.
///
/// `apply_default` must be false for connections initiated on behalf of the service
/// (e.g. "switch sides"), which have to stay on the service's server.
pub fn resolve_id(id: &str, apply_default: bool) -> (String, Option<String>) {
    // Direct IP access and other non-ID addresses are never routed through a profile.
    if crate::common::is_direct_ip_access(id) {
        return (id.to_owned(), None);
    }
    let default_profile = if apply_default {
        LocalConfig::get_option(OPTION_DEFAULT_SERVER_PROFILE)
    } else {
        String::new()
    };
    resolve_id_with(id, &get_profiles(), &default_profile)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn profiles() -> Vec<ServerProfile> {
        parse_profiles(
            r#"[
              {"name":"pwe","host":"rd.pwe-system.at","key":"AbC+/1="},
              {"name":"home","host":"my.nebukad.net:21116","key":""},
              {"name":"bad name","host":"x","key":""},
              {"name":"evil","host":"a?b","key":""},
              {"name":"PWE","host":"dup","key":""}
            ]"#,
        )
    }

    #[test]
    fn parse_filters_invalid_and_duplicates() {
        let p = profiles();
        assert_eq!(p.len(), 2);
        assert_eq!(p[0].name, "pwe");
        assert_eq!(p[1].name, "home");
        assert!(parse_profiles("").is_empty());
        assert!(parse_profiles("not json").is_empty());
    }

    #[test]
    fn explicit_profile() {
        let p = profiles();
        assert_eq!(
            resolve_id_with("123456789@pwe", &p, ""),
            (
                "123456789@rd.pwe-system.at?key=AbC+/1=".to_owned(),
                Some("pwe".to_owned())
            )
        );
        assert_eq!(
            resolve_id_with("123/r@HOME", &p, "pwe").0,
            "123/r@my.nebukad.net:21116"
        );
    }

    #[test]
    fn default_profile() {
        let p = profiles();
        assert_eq!(
            resolve_id_with("123", &p, "home").0,
            "123@my.nebukad.net:21116"
        );
        assert_eq!(resolve_id_with("123", &p, "").0, "123");
        assert_eq!(resolve_id_with("123", &p, "missing").0, "123");
    }

    #[test]
    fn untouched_other_server_syntax() {
        let p = profiles();
        for id in [
            "123@rd.example.com",
            "123@rd.example.com?key=xyz",
            "123@public",
            "123@pwe?key=override",
        ] {
            assert_eq!(resolve_id_with(id, &p, "home"), (id.to_owned(), None));
        }
    }
}
