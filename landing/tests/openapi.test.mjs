import assert from "node:assert/strict";
import { after, before, test } from "node:test";
import { startSiteServer } from "./helpers/site-server.mjs";

let site;
before(async () => { site = await startSiteServer(); });
after(async () => { await site?.close(); });

async function getContract() {
  const response = await fetch(`${site.origin}/openapi.json`);
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type"), /application\/json/);
  return response.json();
}

test("consumers can discover the reviewed API subset and its authentication boundary", async () => {
  const api = await getContract();
  assert.equal(api.openapi, "3.0.3");
  assert.deepEqual(api.servers, [{ url: "https://api.darkbloom.dev" }]);
  assert.deepEqual(Object.keys(api.paths).sort(), ["/v1/chat/completions", "/v1/models", "/v1/models/{id}", "/v1/pricing"]);
  assert.deepEqual(api.security, [{ bearerAuth: [] }]);
  assert.equal(api.components.securitySchemes.bearerAuth.scheme, "bearer");
  assert.deepEqual(api.paths["/v1/pricing"].get.security, []);
  for (const [path, method] of [["/v1/chat/completions", "post"], ["/v1/models", "get"], ["/v1/models/{id}", "get"]]) {
    assert.equal(api.paths[path][method].security, undefined, "protected operations inherit authentication");
    assert.ok(api.paths[path][method].responses["401"]);
  }
  assert.equal(api["x-source-revision"], "baca977134a63678ab12979038d3618901d852ee");
  assert.match(api.info.description, /subset/i);
});

test("model discovery and pricing describe actual response fields and distinct units", async () => {
  const api = await getContract();
  const schemas = api.components.schemas;
  const list = api.paths["/v1/models"].get;
  assert.equal(list.parameters[0].name, "include_builds");
  assert.deepEqual(list.parameters[0].schema.enum, ["1"]);
  assert.equal(list.responses["200"].content["application/json"].schema.$ref, "#/components/schemas/ModelList");
  const retrieve = api.paths["/v1/models/{id}"].get;
  assert.match(retrieve.parameters[0].description, /slash|%2F/);
  assert.ok(retrieve.responses["404"]);
  assert.deepEqual(schemas.Model.required, ["id", "object", "created", "owned_by", "metadata"]);
  assert.equal(schemas.Model.properties.metadata.$ref, "#/components/schemas/ModelMetadata");
  assert.equal(schemas.ModelMetadata.properties.can_accept.type, "boolean");
  assert.match(schemas.ModelPricing.properties.prompt.description, /USD per individual token/);
  assert.match(schemas.PriceEntry.properties.input_price.description, /micro-USD per one million tokens/);
  assert.match(schemas.PriceEntry.properties.input_usd.description, /USD per one million tokens/);
  assert.equal(schemas.PricingResponse.properties.fallback_input_price.type, "integer");
  assert.ok(schemas.PriceEntry.required.includes("cache_read_price"));
  assert.match(api.paths["/v1/pricing"].get.description, /timestamp/i);
});

test("chat clients can distinguish JSON success, pre-content errors and terminal stream errors", async () => {
  const api = await getContract();
  const chat = api.paths["/v1/chat/completions"].post;
  const schemas = api.components.schemas;
  assert.equal(chat.requestBody.required, true);
  assert.equal(chat.requestBody.content["application/json"].schema.$ref, "#/components/schemas/TextChatRequest");
  assert.deepEqual(schemas.TextChatRequest.required, ["model", "messages"]);
  assert.equal(schemas.TextChatRequest.properties.messages.items.$ref, "#/components/schemas/TextChatMessage");
  assert.equal(schemas.TextChatRequest.properties.max_tokens.minimum, 0);
  assert.equal(schemas.TextChatRequest.properties.max_tokens.nullable, true);
  assert.deepEqual(schemas.TextChatRequest.properties.n.enum, [1]);
  assert.match(schemas.TextChatRequest.properties.max_completion_tokens.description, /positive max_tokens takes precedence/);
  assert.equal(chat.responses["200"].content["application/json"].schema.$ref, "#/components/schemas/ChatCompletion");
  const stream = chat.responses["200"].content["text/event-stream"];
  assert.equal(stream.schema.type, "string");
  assert.match(stream.schema.description, /without.*\[DONE\]/s);
  assert.match(stream.schema.description, /first content/i);
  assert.match(stream.examples.success.value, /data: \[DONE\]\n\n$/);
  assert.doesNotMatch(stream.examples.failure.value, /\[DONE\]/);
  assert.equal(chat.responses["429"].headers["Retry-After"].schema.type, "integer");
  for (const status of ["400", "401", "402", "403", "404", "409", "413", "422", "429", "500", "502", "503", "504"]) {
    const response = chat.responses[status];
    assert.ok(response, status);
    assert.equal(response.content["application/json"].schema.$ref, "#/components/schemas/Error", status);
  }
  assert.deepEqual(schemas.Error.properties.error.required, ["message", "type", "code"]);
  assert.equal(schemas.Error.properties.error.properties.param.type, "string");
});

test("the public document is valid OpenAPI with distinct operations and immutable provenance", async () => {
  const { default: SwaggerParser } = await import("@apidevtools/swagger-parser");
  const api = await getContract();
  const validated = await SwaggerParser.validate(structuredClone(api), { resolve: { external: false } });
  assert.equal(validated.info.title, "Darkbloom Consumer API");
  const operations = Object.values(api.paths).flatMap((path) => Object.values(path));
  assert.equal(new Set(operations.map((operation) => operation.operationId)).size, 4);
  for (const operation of operations) {
    assert.ok(operation.description.length > 30);
    assert.ok(operation.responses["200"].content);
  }
  assert.match(api.externalDocs.url, /\/blob\/baca977134a63678ab12979038d3618901d852ee\/docs\/reference\/api-contracts\.md$/);
  assert.ok(api["x-reviewed-source-files"].includes("coordinator/api/routes.go"));
  assert.ok(api["x-reviewed-source-files"].includes("coordinator/api/types/types.go"));
});
