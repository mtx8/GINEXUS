//! Human-in-the-loop policy — DEFAULT-CONFIRM allow-list (Rust core). Port of `hitl.py`.
//! Every state-changing action confirms UNLESS an exact (action, target) pair is allow-listed;
//! read-only actions never confirm. Composite actions resolve TRANSITIVELY via an expander:
//! if any leaf requires confirmation, the whole composite does.

use std::collections::HashSet;

#[derive(Clone)]
pub struct Action {
    pub name: String,
    pub target: String,
    pub read_only: bool,
}

impl Action {
    pub fn new(name: impl Into<String>, target: impl Into<String>) -> Self {
        Self { name: name.into(), target: target.into(), read_only: false }
    }
    pub fn read_only(name: impl Into<String>, target: impl Into<String>) -> Self {
        Self { name: name.into(), target: target.into(), read_only: true }
    }
}

type Expander = Box<dyn Fn(&Action) -> Vec<Action> + Send + Sync>;

pub struct HitlPolicy {
    allow: HashSet<(String, String)>,
    expander: Option<Expander>,
}

impl Default for HitlPolicy {
    fn default() -> Self {
        Self { allow: HashSet::new(), expander: None }
    }
}

impl HitlPolicy {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn allow(&mut self, name: impl Into<String>, target: impl Into<String>) {
        self.allow.insert((name.into(), target.into()));
    }

    pub fn set_expander(&mut self, f: Expander) {
        self.expander = Some(f);
    }

    fn leaf_requires(&self, a: &Action) -> bool {
        if a.read_only {
            return false;
        }
        !self.allow.contains(&(a.name.clone(), a.target.clone()))
    }

    /// True unless every leaf of the (possibly composite) action is read-only or allow-listed.
    pub fn requires_confirmation(&self, action: &Action) -> bool {
        let leaves = match &self.expander {
            Some(f) => f(action),
            None => vec![action.clone()],
        };
        if leaves.is_empty() {
            return true; // fail-safe: an unresolvable action must be confirmed
        }
        leaves.iter().any(|l| self.leaf_requires(l))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_confirms_unknown_action() {
        assert!(HitlPolicy::new().requires_confirmation(&Action::new("mail.send", "a@x.com")));
    }

    #[test]
    fn read_only_never_confirms() {
        assert!(!HitlPolicy::new()
            .requires_confirmation(&Action::read_only("ha.get_state", "light.kitchen")));
    }

    #[test]
    fn allowlisted_pair_skips_confirmation() {
        let mut p = HitlPolicy::new();
        p.allow("ha.call_service", "light.kitchen");
        assert!(!p.requires_confirmation(&Action::new("ha.call_service", "light.kitchen")));
        // a new dangerous domain that nobody allow-listed must still confirm
        assert!(p.requires_confirmation(&Action::new("ha.call_service", "lock.front_door")));
        assert!(p.requires_confirmation(&Action::new("ha.call_service", "valve.water_main")));
    }

    #[test]
    fn scene_with_dangerous_leaf_confirms() {
        let mut p = HitlPolicy::new();
        p.allow("ha.call_service", "light.kitchen");
        p.allow("scene.activate", "scene.goodnight");
        p.set_expander(Box::new(|a: &Action| {
            if a.target == "scene.goodnight" {
                vec![
                    Action::new("ha.call_service", "light.kitchen"),
                    Action::new("ha.call_service", "lock.front_door"), // not allow-listed
                ]
            } else {
                vec![a.clone()]
            }
        }));
        assert!(p.requires_confirmation(&Action::new("scene.activate", "scene.goodnight")));
    }

    #[test]
    fn scene_all_safe_skips_confirmation() {
        let mut p = HitlPolicy::new();
        p.allow("ha.call_service", "light.kitchen");
        p.set_expander(Box::new(|a: &Action| {
            if a.target == "scene.movie" {
                vec![Action::new("ha.call_service", "light.kitchen")]
            } else {
                vec![a.clone()]
            }
        }));
        assert!(!p.requires_confirmation(&Action::new("scene.activate", "scene.movie")));
    }
}
