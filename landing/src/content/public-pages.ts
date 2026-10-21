import { publicFacts } from "./public-site";

export const developerIntroduction = "Use the consumer API to request inference, or run the provider app and CLI to contribute compute. These are separate roles with different credentials and prerequisites.";
export const consumerInstructions = [
  "Sign in to the Console and create an API key in API Console. Keep the key secret and use a funded account for paid fleet inference.",
  "Send Authorization: Bearer <DARKBLOOM_API_KEY> with consumer requests. For the OpenAI SDK, use https://api.darkbloom.dev/v1 as the base URL. A provider device token is not a consumer API key.",
  "List models with GET /v1/models before choosing a model ID. Availability and supported features depend on the model and network capacity. Responses, Messages and legacy Completions are described in the full API reference; the downloadable OpenAPI document covers a reviewed consumer subset.",
] as const;
export const consumerExample = 'curl https://api.darkbloom.dev/v1/models \\\n  -H "Authorization: Bearer $DARKBLOOM_API_KEY"';
export const providerInstructions = [
  "The official darkbloom CLI operates provider software on an eligible Apple Silicon Mac. It is not an npm package or a consumer API client. Check the current hardware, macOS and security requirements before installing.",
  "Use the official installer and provider documentation. Run darkbloom doctor to check the Mac, darkbloom login to link it to your account, and darkbloom start to begin serving. darkbloom status reports the local provider state.",
] as const;
export const providerExample = "# On an eligible Mac, after following the official installation guide\ndarkbloom doctor\ndarkbloom login\ndarkbloom start\ndarkbloom status";
export const developerPrivacy = publicFacts.privacy;
export const contactIntroduction = "Find the right official resource for Darkbloom, whether you are integrating the consumer API, operating a provider Mac, or sending a legal notice.";
export const legalContactDescription = "For legal notices, contact Eigen Labs, Inc., the operator of Darkbloom, at the address published in the Terms of Service. This is a legal-notices contact; no response time or technical support service is promised here.";

export const homepageOverview = "Darkbloom connects Apple Silicon Macs into a decentralized private inference network. Providers contribute compute with the app and CLI. Consumers use the authenticated OpenAI-compatible API to run models, with usage-based token pricing.";
