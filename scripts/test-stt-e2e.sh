#!/bin/bash
# End-to-end test for STT transcription through the d-inference network.
#
# Prerequisites:
#   - mlx-audio server running on port 8001 with a Cohere transcribe model
#   - coordinator running
#   - provider connected with STT model advertised
#
# This script tests the coordinator's /v1/audio/transcriptions endpoint
# by sending a short audio clip and verifying the transcription.

set -euo pipefail

COORDINATOR_URL="${COORDINATOR_URL:-http://localhost:8080}"
API_KEY="${API_KEY:-test-key}"
AUDIO_FILE="${1:-/tmp/elon_test_30s.wav}"
MODEL="${2:-CohereLabs/cohere-transcribe-03-2026}"

echo "=== DGInf STT End-to-End Test ==="
echo "Coordinator: $COORDINATOR_URL"
echo "Audio file: $AUDIO_FILE"
echo "Model: $MODEL"
echo ""

# Check audio file exists
if [ ! -f "$AUDIO_FILE" ]; then
    echo "ERROR: Audio file not found: $AUDIO_FILE"
    exit 1
fi

echo "Sending transcription request..."
RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST "$COORDINATOR_URL/v1/audio/transcriptions" \
    -H "Authorization: Bearer $API_KEY" \
    -F "file=@$AUDIO_FILE" \
    -F "model=$MODEL" \
    -F "language=en")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)

echo "HTTP Status: $HTTP_CODE"
echo ""

if [ "$HTTP_CODE" -eq 200 ]; then
    echo "=== Transcription Result ==="
    echo "$BODY" | python3 -m json.tool 2>/dev/null || echo "$BODY"
    echo ""

    # Extract just the text
    TEXT=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('text','')[:200])" 2>/dev/null || echo "")
    if [ -n "$TEXT" ]; then
        echo "=== First 200 chars ==="
        echo "$TEXT"
        echo ""
        echo "SUCCESS: Transcription received!"
    fi
else
    echo "ERROR: Request failed"
    echo "$BODY"
    exit 1
fi
