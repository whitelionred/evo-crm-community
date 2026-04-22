#!/usr/bin/env bash
# =============================================================================
# fix-channel-state.sh — applies bugs #1, #2, #3 fixes to a newly-created
# Evolution WhatsApp channel in the CRM
# =============================================================================
# Upstream bugs (see CUSTOMIZATIONS.md §Runtime-state fixes):
#   #1  Channel creation doesn't persist api_url / admin_token
#   #2  reauthorization_required defaults to true
#   #3  provider_connection stuck on the last disconnect state
#
# Usage:
#   bash scripts/fix-channel-state.sh [--all | <channel_uuid>]
#
# Requires EVOLUTION_API_KEY and EVOLUTION_API_URL env vars, or defaults
# to what bootstrap.sh sets up.
# =============================================================================

set -euo pipefail

API_URL="${EVOLUTION_API_URL:-http://host.docker.internal:58081}"
API_KEY="${EVOLUTION_API_KEY:-}"

if [ -z "$API_KEY" ] && [ -f "evolution-api/.env" ]; then
  API_KEY="$(grep -E '^AUTHENTICATION_API_KEY=' evolution-api/.env | cut -d= -f2-)"
fi

if [ -z "$API_KEY" ]; then
  echo "ERROR: EVOLUTION_API_KEY not set and could not be read from evolution-api/.env"
  exit 1
fi

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  echo "Usage: $0 [--all | <channel_uuid>]"
  exit 1
fi

if [ "$TARGET" = "--all" ]; then
  WHERE="WHERE provider IN ('evolution', 'evolution_go')"
else
  WHERE="WHERE id = '${TARGET}'"
fi

echo "[1/3] Injecting api_url and admin_token into provider_config..."
docker compose exec -T postgres psql -U postgres -d evo_community -c "
UPDATE channel_whatsapp
SET provider_config = provider_config || jsonb_build_object(
  'api_url',     '${API_URL}',
  'admin_token', '${API_KEY}'
)
${WHERE};"

echo "[2/3] Resetting provider_connection to connected..."
docker compose exec -T postgres psql -U postgres -d evo_community -c "
UPDATE channel_whatsapp
SET provider_connection = '{\"connection\": \"connected\"}'
${WHERE};"

echo "[3/3] Clearing reauthorization flag via Rails runner..."
docker compose exec -T evo-crm sh -c "bundle exec rails runner 'Channel::Whatsapp.where(provider: %w[evolution evolution_go]).each(&:reauthorized!)'"

echo ""
echo "Done. The channel should now:"
echo "  - Accept QR code generation requests"
echo "  - Process incoming webhooks into conversations"
echo "  - Accept agent replies"
echo ""
echo "Next: from the WhatsApp contact's phone, close any other WhatsApp Web"
echo "sessions on the linked number (Settings > Linked Devices) and send a"
echo "test message to the linked number."
