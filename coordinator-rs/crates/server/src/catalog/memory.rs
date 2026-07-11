//! Immutable in-memory catalog restricted to one text model.

use std::{collections::BTreeSet, sync::Arc};

use darkbloom_coordinator_core::{ids::ModelId, money::MicroUsd, tokens::TokenCount};
use thiserror::Error;

/// One concrete text-only model and its frozen public pricing.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TextModel {
    /// Concrete model/build identifier used for provider matching.
    pub id: ModelId,
    /// Public aliases accepted by consumer requests.
    pub aliases: BTreeSet<Arc<str>>,
    /// Maximum prompt plus output context.
    pub maximum_context_tokens: TokenCount,
    /// Exact micro-USD charged per million input tokens.
    pub input_micro_usd_per_million: MicroUsd,
    /// Exact micro-USD charged per million output tokens.
    pub output_micro_usd_per_million: MicroUsd,
}

impl TextModel {
    /// Creates one text model and validates a finite alias set.
    pub fn new(
        id: ModelId,
        aliases: impl IntoIterator<Item = Arc<str>>,
        maximum_context_tokens: TokenCount,
        input_micro_usd_per_million: MicroUsd,
        output_micro_usd_per_million: MicroUsd,
    ) -> Result<Self, MemoryCatalogError> {
        if maximum_context_tokens.get() == 0 {
            return Err(MemoryCatalogError::ZeroContext);
        }
        let aliases: BTreeSet<_> = aliases.into_iter().collect();
        if aliases.len() > 32 {
            return Err(MemoryCatalogError::TooManyAliases { maximum: 32 });
        }
        for alias in &aliases {
            if alias.is_empty()
                || alias.len() > 256
                || alias.trim() != alias.as_ref()
                || alias.chars().any(char::is_control)
            {
                return Err(MemoryCatalogError::InvalidAlias(alias.clone()));
            }
        }
        Ok(Self {
            id,
            aliases,
            maximum_context_tokens,
            input_micro_usd_per_million,
            output_micro_usd_per_million,
        })
    }
}

/// Process-local catalog with exactly one configured text model.
#[derive(Clone, Debug)]
pub struct MemoryCatalog {
    model: TextModel,
}

impl MemoryCatalog {
    /// Installs the sole text model.
    #[must_use]
    pub fn new(model: TextModel) -> Self {
        Self { model }
    }

    /// Resolves either the concrete ID or one configured alias.
    #[must_use]
    pub fn resolve(&self, requested: &str) -> Option<&TextModel> {
        (requested == self.model.id.as_str()
            || self
                .model
                .aliases
                .iter()
                .any(|alias| alias.as_ref() == requested))
        .then_some(&self.model)
    }

    /// Iterates the exactly one model.
    pub fn models(&self) -> impl ExactSizeIterator<Item = &TextModel> {
        std::iter::once(&self.model)
    }

    /// Concrete model count, pinned to one by type shape.
    #[must_use]
    pub const fn len(&self) -> usize {
        1
    }

    /// A one-model catalog is never empty.
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        false
    }
}

/// Invalid one-model catalog configuration.
#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum MemoryCatalogError {
    /// Text model must expose a nonzero context window.
    #[error("text model context window must be greater than zero")]
    ZeroContext,
    /// Alias set exceeds its finite bound.
    #[error("text model alias count exceeds {maximum}")]
    TooManyAliases {
        /// Hard alias bound.
        maximum: usize,
    },
    /// Alias is empty, ambiguous, oversized, or contains controls.
    #[error("invalid text model alias {0:?}")]
    InvalidAlias(Arc<str>),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_contains_exactly_one_text_model_and_alias() {
        let model = TextModel::new(
            ModelId::new("qwen/text-build").expect("id"),
            [Arc::from("qwen-text")],
            TokenCount::new(32_768),
            MicroUsd::new(50_000),
            MicroUsd::new(200_000),
        )
        .expect("model");
        let catalog = MemoryCatalog::new(model);
        assert_eq!(catalog.models().len(), 1);
        assert!(catalog.resolve("qwen/text-build").is_some());
        assert!(catalog.resolve("qwen-text").is_some());
        assert!(catalog.resolve("unknown").is_none());
    }
}
