"""Read-only source/dependency verification for this isolated build."""
import json
from build_inputs import verify

if __name__ == '__main__':
    print(json.dumps(verify(), sort_keys=True))
