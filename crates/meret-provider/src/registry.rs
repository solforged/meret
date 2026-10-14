use std::sync::Arc;

use crate::{Catalog, Health, Provider, ThreadSource, ZoneHost};

#[derive(Default, Clone)]
pub struct Registry {
    providers: Vec<Arc<dyn Provider>>,
}

impl Registry {
    pub fn add(&mut self, p: Arc<dyn Provider>) {
        self.providers.push(p);
    }

    pub fn all(&self) -> &[Arc<dyn Provider>] {
        &self.providers
    }

    pub fn get(&self, key: &str) -> Option<&Arc<dyn Provider>> {
        self.providers.iter().find(|p| p.key() == key)
    }

    pub fn catalogs(&self) -> impl Iterator<Item = (&'static str, &dyn Catalog)> {
        self.providers.iter().filter_map(|p| p.as_catalog().map(|c| (p.key(), c)))
    }

    pub fn thread_sources(&self) -> impl Iterator<Item = (&'static str, &dyn ThreadSource)> {
        self.providers.iter().filter_map(|p| p.as_threads().map(|c| (p.key(), c)))
    }

    pub fn zone_hosts(&self) -> impl Iterator<Item = (&'static str, &dyn ZoneHost)> {
        self.providers.iter().filter_map(|p| p.as_zone_host().map(|c| (p.key(), c)))
    }

    /// For the status line.
    pub fn health(&self) -> Vec<(&'static str, Health)> {
        self.providers.iter().map(|p| (p.name(), p.health())).collect()
    }
}
