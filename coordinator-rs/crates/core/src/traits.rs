//! Request-to-provider capability compatibility.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::tokens::TokenCount;

/// A provider capability that may be required by a request.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Capability {
    /// JSON-schema tool calling.
    Tools,
    /// Image or other multimodal request parts.
    Multimodal,
    /// Strict response-schema generation.
    StructuredOutput,
}

/// Traits that affect provider compatibility for one request.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct RequestTraits {
    context_tokens: TokenCount,
    required_capabilities: BTreeSet<Capability>,
}

impl RequestTraits {
    /// Creates request traits with no optional capabilities.
    #[must_use]
    pub fn new(context_tokens: TokenCount) -> Self {
        Self {
            context_tokens,
            required_capabilities: BTreeSet::new(),
        }
    }

    /// Adds a required capability.
    #[must_use]
    pub fn requiring(mut self, capability: Capability) -> Self {
        self.required_capabilities.insert(capability);
        self
    }

    /// Returns the request's total context requirement.
    #[must_use]
    pub const fn context_tokens(&self) -> TokenCount {
        self.context_tokens
    }

    /// Returns the deterministically ordered required capabilities.
    pub fn required_capabilities(&self) -> impl Iterator<Item = Capability> + '_ {
        self.required_capabilities.iter().copied()
    }
}

/// Provider and loaded-model traits relevant to routing.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ProviderTraits {
    maximum_context_tokens: TokenCount,
    capabilities: BTreeSet<Capability>,
    template_render_ok: bool,
}

impl ProviderTraits {
    /// Creates provider traits.
    #[must_use]
    pub fn new(
        maximum_context_tokens: TokenCount,
        capabilities: impl IntoIterator<Item = Capability>,
        template_render_ok: bool,
    ) -> Self {
        Self {
            maximum_context_tokens,
            capabilities: capabilities.into_iter().collect(),
            template_render_ok,
        }
    }

    /// Checks all compatibility constraints.
    pub fn check(&self, request: &RequestTraits) -> Result<(), CompatibilityError> {
        if !self.template_render_ok {
            return Err(CompatibilityError::TemplateRenderFailed);
        }
        if request.context_tokens > self.maximum_context_tokens {
            return Err(CompatibilityError::ContextTooLarge {
                requested: request.context_tokens,
                maximum: self.maximum_context_tokens,
            });
        }
        if let Some(missing) = request
            .required_capabilities
            .difference(&self.capabilities)
            .next()
            .copied()
        {
            return Err(CompatibilityError::MissingCapability(missing));
        }
        Ok(())
    }

    /// Returns whether the scan-time template render check passed.
    #[must_use]
    pub const fn template_render_ok(&self) -> bool {
        self.template_render_ok
    }
}

/// A deterministic reason a request cannot use a provider.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum CompatibilityError {
    /// The loaded model failed its scan-time template render check.
    #[error("model chat template failed its render check")]
    TemplateRenderFailed,
    /// The request exceeds the model's context window.
    #[error("requested {requested:?} tokens exceeds maximum {maximum:?}")]
    ContextTooLarge {
        /// Requested context tokens.
        requested: TokenCount,
        /// Maximum model context tokens.
        maximum: TokenCount,
    },
    /// The provider lacks a required capability.
    #[error("provider is missing capability {0:?}")]
    MissingCapability(Capability),
}

#[cfg(test)]
mod tests {
    use super::{Capability, CompatibilityError, ProviderTraits, RequestTraits};
    use crate::tokens::TokenCount;

    #[test]
    fn template_failure_fences_every_request_shape() {
        let provider = ProviderTraits::new(TokenCount::new(8_192), [], false);
        let request = RequestTraits::new(TokenCount::new(1));
        assert_eq!(
            provider.check(&request),
            Err(CompatibilityError::TemplateRenderFailed)
        );
    }

    #[test]
    fn required_capability_and_context_are_checked() {
        let provider = ProviderTraits::new(TokenCount::new(100), [], true);
        assert_eq!(
            provider.check(&RequestTraits::new(TokenCount::new(101))),
            Err(CompatibilityError::ContextTooLarge {
                requested: TokenCount::new(101),
                maximum: TokenCount::new(100),
            })
        );
        assert_eq!(
            provider.check(&RequestTraits::new(TokenCount::new(1)).requiring(Capability::Tools)),
            Err(CompatibilityError::MissingCapability(Capability::Tools))
        );
    }
}
