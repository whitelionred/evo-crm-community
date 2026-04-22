# CUSTOMIZATIONS — fork `whitelionred/evo-crm-community`

**Last updated:** 2026-04-22
**Owner:** [@whitelionred](https://github.com/whitelionred)
**Upstream tracked:** `EvolutionAPI/evo-crm-community` @ commit `833bcd9` (submodule `evo-ai-crm-community`)

This document is the **authoritative log** of every local change applied on top
of upstream. Every time we pull upstream, this file must stay in sync with the
actual state of the repo. Each entry below includes the symptom, the fix, the
affected files, and how to verify.

---

## Repository layout

```
whitelionred/evo-crm-community  (this monorepo fork, branch: local-fixes)
│
├── upstream: EvolutionAPI/evo-crm-community
│
└── submodules:
    └── whitelionred/evo-ai-crm-community  (forked, branch: local-fixes)
         └── upstream: EvolutionAPI/evo-ai-crm-community

    Other submodules (still pointing to EvolutionAPI/*, not forked):
      - evo-auth-service-community
      - evo-ai-frontend-community
      - evo-ai-processor-community
      - evo-ai-core-service-community
      - evo-bot-runtime
      - evolution-api
      - evolution-go
```

**Rule of thumb:** only fork a submodule if we need to patch its code.
Environmental tweaks go in override files that live in the monorepo fork.

---

## Port remaps (local host)

Motivation: another Docker stack on the same machine (Lexos) already binds
5432, 6379, 3000. We remap our host ports to avoid conflicts. Container
internals unchanged.

| Service            | Container port | Host port | File |
|--------------------|----------------|-----------|------|
| `postgres`         | 5432           | **55432** | `docker-compose.override.yaml` |
| `redis`            | 6379           | **56379** | `docker-compose.override.yaml` |
| `evo-bot-runtime`  | 8080           | **58080** | `docker-compose.override.yaml` |
| `api` (evolution)  | 8080           | **58081** | `evolution-api/docker-compose.override.yaml` |
| `frontend` (evo-manager) | 80       | **53000** | `evolution-api/docker-compose.override.yaml` |

The monorepo override is committed. The `evolution-api/docker-compose.override.yaml`
is **intentionally untracked** inside that submodule — it is registered in
`.git/modules/evolution-api/info/exclude` so it stays local-only and does not
interfere with upstream pulls. `scripts/bootstrap.sh` recreates it.

---

## `.env` changes (not committed — secrets live here)

After `cp .env.example .env`, apply these diffs:

```diff
-BACKEND_URL=http://localhost:3000
+BACKEND_URL=http://host.docker.internal:3000
```

**Why:** the CRM backend creates Evolution API instances with a webhook URL
pointing to `BACKEND_URL`. Inside the evolution-api container, `localhost:3000`
resolves to the container itself — the webhook never reaches the CRM.
`host.docker.internal` is Docker Desktop's DNS entry pointing to the host.

For `evolution-api/.env` (created from `env.example`), apply:

```diff
-DATABASE_CONNECTION_URI=postgresql://username:password@localhost:5432/evolution_api
+DATABASE_CONNECTION_URI=postgresql://evolution:evolution_dev_password@evolution-postgres:5432/evolution_api?schema=public

-CACHE_REDIS_URI=redis://localhost:6379
+CACHE_REDIS_URI=redis://evolution-redis:6379

-AUTHENTICATION_API_KEY=BQYHJGJHJ
+AUTHENTICATION_API_KEY=<strong random value>
```

Also add (not present in upstream `env.example`):

```
POSTGRES_DATABASE=evolution_api
POSTGRES_USERNAME=evolution
POSTGRES_PASSWORD=evolution_dev_password
```

These last three are **required** — the compose file references them but upstream
`env.example` doesn't declare them. Without them `evolution-postgres` fails
with empty DB credentials.

---

## Code patches

### Patch #1 — `evo-ai-crm-community`: use keyId as `raw_message_id`

**Status:** committed to `whitelionred/evo-ai-crm-community@local-fixes` (commit `95eb1cb`)

**File:** [`app/services/whatsapp/evolution_handlers/helpers.rb`](evo-ai-crm-community/app/services/whatsapp/evolution_handlers/helpers.rb#L6)

**Symptom:** double-tick (delivered) and blue-tick (read) indicators never
appeared on outgoing messages sent through the Evolution channel. Sidekiq
logged `"Outgoing message not found for update: <id>"` for every
`messages.update` event.

**Root cause:** the helper prioritized `:messageId` (Evolution API's internal
CUID, e.g. `cmo7mabs3007qmd7a1lma9tti`) over `:keyId` (the WhatsApp-native
message ID, e.g. `3EB02031F9AC3AC5CC35EC`). Outgoing messages are stored in
the CRM with `source_id = keyId`, so the lookup always missed.

**Fix:**
```ruby
# Before:
@raw_message[:messageId] || @raw_message[:keyId] || @raw_message.dig(:key, :id)

# After:
@raw_message[:keyId] || @raw_message.dig(:key, :id) || @raw_message[:messageId]
```

**Verify:** after sending an outbound message from the CRM, the corresponding
row in `messages` should progress from `status=0` (sent) to `1` (delivered)
to `2` (read) as the recipient interacts. Sidekiq should log
`Updating message <keyId> status to delivered/read`.

**Upstream status:** not reported. When an upstream fix lands, rebase our
`local-fixes` branch and drop this commit if identical.

---

## Runtime-state fixes (DB-level, must be re-applied on fresh setups)

These are bugs in the CRM's WhatsApp channel creation flow. Until the fixes
are upstreamed, every freshly-created Evolution channel needs manual DB
surgery. Run `scripts/fix-channel-state.rb` after creating a channel.

### Bug #1 — `provider_config` missing `api_url` and `admin_token`

**Symptom:** QR generation fails with `NoMethodError - undefined method 'chomp' for nil`.

**Root cause:** the channel-creation controller
(`Api::V1::Evolution::AuthorizationsController`) passes these values to
Evolution API during instance creation but never persists them into the
`channel_whatsapp.provider_config` JSON column.

**Manual fix (DB):**
```sql
UPDATE channel_whatsapp
SET provider_config = provider_config || jsonb_build_object(
  'api_url',     'http://host.docker.internal:58081',
  'admin_token', '<YOUR_EVOLUTION_API_KEY>'
)
WHERE provider = 'evolution';
```

### Bug #2 — New channels marked `reauthorization_required = true` from the start

**Symptom:** incoming webhooks are silently discarded with the log line
`WARN: Inactive WhatsApp channel: +<phone>`. Conversations never get created.

**Root cause:** the channel's `reauthorization_required?` flag defaults to
`true` on creation. The webhook job checks `channel_is_inactive?` which
returns `true` while the flag is set.

**Manual fix (Rails runner):**
```ruby
Channel::Whatsapp.where(provider: %w[evolution evolution_go]).each(&:reauthorized!)
```

### Bug #3 — `provider_connection` not reset when WhatsApp reconnects

**Symptom:** after a transient disconnect (e.g. `statusReason: 428`), the
CRM UI keeps showing a "Connection closed" banner and disables reply input
even though the WhatsApp session has already reconnected (`state: open`).

**Root cause:** the `connection.update` handler writes to
`channel_whatsapp.provider_connection` when the state goes to `close` but
does not reset it when the state returns to `open`.

**Manual fix (SQL):**
```sql
UPDATE channel_whatsapp
SET provider_connection = '{"connection": "connected"}'
WHERE provider = 'evolution' AND provider_connection->>'connection' != 'connected';
```

### Bug #4 — Webhook URL baked as `localhost:3000` on channel creation

**Symptom:** no webhook events reach the CRM until the webhook URL on the
Evolution instance is patched.

**Root cause:** channel creation sends `BACKEND_URL` as the webhook URL.
If `BACKEND_URL=http://localhost:3000` (the upstream default), Evolution
stores that literal value and tries to POST to its own container.

**Prevention:** always set `BACKEND_URL=http://host.docker.internal:3000`
in `.env` *before* creating any Evolution channel (see `.env changes`
section above). For existing channels:
```bash
curl -X POST -H "apikey: $KEY" -H "Content-Type: application/json" \
  -d '{"webhook":{"enabled":true,"url":"http://host.docker.internal:3000/webhooks/whatsapp/evolution","webhookByEvents":false,"webhookBase64":true,"events":["CONNECTION_UPDATE","CONTACTS_SET","CONTACTS_UPDATE","CONTACTS_UPSERT","LABELS_ASSOCIATION","LABELS_EDIT","LOGOUT_INSTANCE","MESSAGES_DELETE","MESSAGES_UPDATE","MESSAGES_UPSERT","SEND_MESSAGE"]}}' \
  "http://localhost:58081/webhook/set/<INSTANCE_NAME>"
```

### Bug #5 — URL-encoding missing for instance names with spaces

**Symptom:** creating a channel with an instance name containing a space
("WhatsApp Evolution") fails with `bad URI (is not URI?)`. The instance
is actually created on Evolution's side but the CRM rolls back its own
record.

**Workaround:** **never use spaces in instance names**. Use
`whatsapp_evolution`, `wa-main`, etc.

### Bug #6 — SSH URLs in `.gitmodules` (merged into our fork)

Upstream ships `.gitmodules` with `git@github.com:` URLs which require an
SSH key configured on GitHub. We replaced them with `https://` URLs. This
is a QoL diff that may be upstreamed independently.

---

## Pending (not yet implemented)

### Feature: typing/presence indicators

- **Outbound** (agent → contact): CRM would need to listen on the
  `conversation.typing_on/off` ActionCable channel and call
  `POST /chat/sendPresence/{instance}` with `composing`/`paused`.
  Nothing exists in `evolution_service.rb` yet.
- **Inbound** (contact → agent): requires adding `PRESENCE_UPDATE` to the
  webhook event list on the Evolution instance, creating a
  `evolution_handlers/presence_update.rb` handler, and wiring it into
  the event dispatcher in `incoming_message_evolution_service.rb`.

Estimated ~40-60 lines of Ruby across 3 files.

---

## Sync-upstream procedure

Run `scripts/sync-upstream.sh`. What it does, in order:

1. **Submodule fork** — `cd evo-ai-crm-community && git fetch upstream &&
   git rebase upstream/main` (on `local-fixes` branch). Then `git push
   --force-with-lease origin local-fixes`.
2. **Monorepo fork** — `cd .. && git fetch upstream && git rebase
   upstream/main` (on `local-fixes` branch).
3. **Submodule pointer** — `git submodule update --remote --merge
   evo-ai-crm-community`. Commit the updated pointer.
4. **Rebuild** — `docker compose build evo-crm evo-crm-sidekiq` and
   restart.
5. **Verify patches still semantically correct** — the rebase will bail
   if our `helpers.rb` patch hits a conflict. If it does, open the file,
   resolve, and re-test outbound message status updates.
6. **Re-test** — run `scripts/smoke-test.sh` (TODO).

---

## File index

| Path | Purpose |
|------|---------|
| `CUSTOMIZATIONS.md` | **this file** — source of truth |
| `docker-compose.override.yaml` | Monorepo port remaps |
| `evolution-api/docker-compose.override.yaml` | Evolution API port remaps (untracked in submodule via `.git/info/exclude`) |
| `.gitmodules` | `evo-ai-crm-community` URL → `whitelionred` fork; all URLs HTTPS |
| `scripts/bootstrap.sh` | First-time setup after cloning this fork |
| `scripts/fix-channel-state.rb` | Rails runner applying bugs #1 / #2 / #3 fixes to an existing channel |
| `scripts/sync-upstream.sh` | Pull upstream into our fork on both repos |
| `patches/` | Reserved — currently empty (fixes live in the forked submodule branch, not as patches) |
