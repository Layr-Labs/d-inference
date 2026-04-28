#!/bin/bash
# Deploy ACME device-attest-01 support to the coordinator server.
# Run from repo root: ./scripts/deploy-acme.sh
#
# This script:
# 1. Adds nginx proxy for step-ca ACME endpoint
# 2. Uploads the new enrollment profile with ACME payload
# 3. Verifies the ACME directory is accessible

set -euo pipefail

SERVER="ubuntu@34.197.17.112"
SSH="ssh -o ConnectTimeout=15 -i ~/.ssh/eigeninference-infra $SERVER"
SCP="scp -o ConnectTimeout=15 -i ~/.ssh/eigeninference-infra"

echo "=== Step 1: Add ACME proxy to nginx ==="
$SSH '
if ! grep -q "/acme/" /etc/nginx/sites-enabled/eigeninference-mdm; then
  sudo sed -i "/# SCEP/i\\\\n    # step-ca ACME (device-attest-01)\\n    location /acme/ {\\n        proxy_pass https://127.0.0.1:9000;\\n        proxy_ssl_verify off;\\n        proxy_set_header Host api.darkbloom.dev;\\n    }" /etc/nginx/sites-enabled/eigeninference-mdm
  sudo nginx -t && sudo systemctl reload nginx
  echo "nginx: ACME proxy added"
else
  echo "nginx: ACME proxy already exists"
fi
'

echo ""
echo "=== Step 2: Upload new enrollment profile ==="
$SCP scripts/enroll-with-acme.mobileconfig $SERVER:/tmp/enroll.mobileconfig
$SSH '
sudo cp /var/www/html/enroll.mobileconfig /var/www/html/enroll.mobileconfig.bak
sudo mv /tmp/enroll.mobileconfig /var/www/html/enroll.mobileconfig
echo "Enrollment profile updated"
'

echo ""
echo "=== Step 3: Verify ACME endpoint ==="
curl -s https://api.darkbloom.dev/acme/eigeninference-acme/directory | python3 -m json.tool

echo ""
echo "=== Done ==="
echo "Next steps:"
echo "  1. On each Mac: System Settings > General > Device Management > Remove Darkbloom profile"
echo "  2. Re-install: open https://api.darkbloom.dev/enroll.mobileconfig"
echo "  3. macOS will generate SE key and complete ACME device-attest-01 challenge"
echo "  4. step-ca issues a certificate binding the SE key to the device identity"
echo "  5. Coordinator can verify the cert chain: step-ca CA → Apple attestation → SE key"
