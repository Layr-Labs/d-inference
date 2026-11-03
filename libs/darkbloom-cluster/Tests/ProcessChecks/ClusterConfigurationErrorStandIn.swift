/// The provider's configuration error, reduced to the case `ClusterModelFeaturePolicy`
/// throws. The pipe contract compiles that policy, whose logprob rule
/// `DistributedResidentExecution` reads, without the provider's configuration files.
enum ClusterConfigurationError: Error { case invalid(String) }
