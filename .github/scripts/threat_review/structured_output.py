"""Bedrock's supported JSON schema projection; local validation stays authoritative.

Adapted from bedrock-codescan-template PR #12 at
1b4f75ca551f73a44edaf7f201793af26b6535c7; see bedrock-upstream-LICENSE.
"""
import copy
import json


def bedrock_schema(schema):
    result = copy.deepcopy(schema)

    def visit(node):
        if not isinstance(node, dict):
            return
        # These bounds are rejected by the native grammar. Keep them visible to
        # the model and enforce the original contract after the response.
        bounds = {key: node.pop(key) for key in ("minLength", "maxLength", "maxItems", "minimum")
                  if key in node}
        if bounds:
            node["description"] = (node.get("description", "") +
                                   "\nLocally enforced constraints: " + json.dumps(bounds, sort_keys=True))
        for child in node.get("properties", {}).values():
            visit(child)
        visit(node.get("items"))

    visit(result)
    return result
