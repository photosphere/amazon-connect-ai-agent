#!/usr/bin/env bash
#
# create_connect_ai_agents.sh
#
# Provisions Amazon Q in Connect resources for a target Amazon Connect instance:
#   - 2 AI Prompts : SelfServiceOrchestrationVoice_Prompt, SelfServiceOrchestrationChat_Prompt
#   - 2 AI Agents  : SelfServiceOrchestrator_Voice_Agent, SelfServiceOrchestrator_Chat_Agent
#                    (tools reduced to only "Complete" and "Escalate")
#   - 1 Security Profile : AI-Agent
#
# Each prompt/agent is cloned from a reference (template) resource that already
# exists in a reference assistant. The reference template configuration is read
# with get-ai-prompt / get-ai-agent and re-created in the target instance's
# Q in Connect assistant with the new name.
#
# APIs used:
#   https://docs.aws.amazon.com/connect/latest/APIReference/API_amazon-q-connect_CreateAIPrompt.html
#   https://docs.aws.amazon.com/connect/latest/APIReference/API_amazon-q-connect_CreateAIAgent.html
#
# Requirements: awscli v2, jq, curl (with --aws-sigv4). Credentials must be able to
# read the reference assistant and write to the target instance's assistant +
# create/associate security profiles.
#
# Usage:
#   ./create_connect_ai_agents.sh <TARGET_CONNECT_INSTANCE_ARN> [TARGET_ASSISTANT_ARN]
#
# Example:
#   ./create_connect_ai_agents.sh arn:aws:connect:us-west-2:111122223333:instance/abcd-...
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Reference (template) resources. Override via environment variables if needed.
# ----------------------------------------------------------------------------
REF_ASSISTANT_ARN="${REF_ASSISTANT_ARN:-arn:aws:wisdom:us-west-2:991727053196:assistant/14fe4db3-cca0-4c91-b484-ee7dc6a0e9aa}"

REF_VOICE_PROMPT_ID="${REF_VOICE_PROMPT_ID:-29fe015d-cd30-4326-a550-af4257793df3}"
REF_CHAT_PROMPT_ID="${REF_CHAT_PROMPT_ID:-917599c0-cb58-4262-b187-8498f7e308f4}"
REF_VOICE_AGENT_ID="${REF_VOICE_AGENT_ID:-1ad99f3e-e69c-4477-b45e-36b8b56a0449}"
REF_CHAT_AGENT_ID="${REF_CHAT_AGENT_ID:-f01b8be1-b98b-40b9-b942-3ffc62c14e57}"

# New resource names.
VOICE_PROMPT_NAME="SelfServiceOrchestrationVoice_Prompt"
CHAT_PROMPT_NAME="SelfServiceOrchestrationChat_Prompt"
VOICE_AGENT_NAME="SelfServiceOrchestrator_Voice_Agent"
CHAT_AGENT_NAME="SelfServiceOrchestrator_Chat_Agent"
SECURITY_PROFILE_NAME="AI-Agent"

# Name + description used when a new Q in Connect assistant ("domain") must be
# created because the target instance has none yet. KB is created and associated
# too so the assistant is fully functional. Override via environment variables.
NEW_ASSISTANT_NAME="${NEW_ASSISTANT_NAME:-${VOICE_AGENT_NAME%_*}-Assistant}"
NEW_KNOWLEDGE_BASE_NAME="${NEW_KNOWLEDGE_BASE_NAME:-${VOICE_AGENT_NAME%_*}-KnowledgeBase}"
# Set CREATE_KNOWLEDGE_BASE=false to only create+associate the assistant.
CREATE_KNOWLEDGE_BASE="${CREATE_KNOWLEDGE_BASE:-true}"

# Tools to keep on the AI agents.
KEEP_TOOLS='["Complete","Escalate"]'

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
log()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m  %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[FAIL]\033[0m  %s\n' "$*" >&2; exit 1; }

# region_from_arn <arn>  ->  prints the region segment (4th field)
region_from_arn() { echo "$1" | awk -F: '{print $4}'; }

# ----------------------------------------------------------------------------
# Argument & dependency validation
# ----------------------------------------------------------------------------
command -v aws >/dev/null 2>&1 || die "aws CLI not found. Install AWS CLI v2."
command -v jq  >/dev/null 2>&1 || die "jq not found. Install jq (e.g. 'brew install jq')."

TARGET_INSTANCE_ARN="${1:-}"
TARGET_ASSISTANT_ARN="${2:-}"

# Prompt for the target Connect instance ARN if it was not supplied.
if [ -z "$TARGET_INSTANCE_ARN" ]; then
  printf 'Enter the target Amazon Connect instance ARN: '
  read -r TARGET_INSTANCE_ARN
  [ -n "$TARGET_INSTANCE_ARN" ] || die "No Connect instance ARN provided."
fi

case "$TARGET_INSTANCE_ARN" in
  arn:aws:connect:*:*:instance/*) : ;;
  *) die "First argument must be a Connect instance ARN (arn:aws:connect:<region>:<acct>:instance/<id>)." ;;
esac

TARGET_INSTANCE_ID="${TARGET_INSTANCE_ARN##*/}"
TARGET_REGION="$(region_from_arn "$TARGET_INSTANCE_ARN")"
REF_REGION="$(region_from_arn "$REF_ASSISTANT_ARN")"

log "Target Connect instance : $TARGET_INSTANCE_ARN"
log "Target instance ID      : $TARGET_INSTANCE_ID"
log "Target region           : $TARGET_REGION"
log "Reference assistant     : $REF_ASSISTANT_ARN ($REF_REGION)"

# ----------------------------------------------------------------------------
# Resolve (or create) the target Q in Connect assistant ("domain")
# ----------------------------------------------------------------------------

# create_qic_domain : creates a Q in Connect assistant (+ optional knowledge
# base), associates them with the Connect instance, and sets TARGET_ASSISTANT_ARN.
create_qic_domain() {
  log "No assistant found. Creating a new Q in Connect domain for the instance..."

  # 1. Assistant
  local assistant_json new_assistant_arn new_assistant_id
  assistant_json="$(aws qconnect create-assistant \
    --name "$NEW_ASSISTANT_NAME" \
    --type AGENT \
    --description "Q in Connect assistant auto-created for AI agents." \
    --region "$TARGET_REGION" \
    --output json)" || die "create-assistant failed."
  new_assistant_arn="$(echo "$assistant_json" | jq -r '.assistant.assistantArn')"
  new_assistant_id="$(echo "$assistant_json" | jq -r '.assistant.assistantId')"
  ok "Created assistant '$NEW_ASSISTANT_NAME' -> $new_assistant_id"

  # 2. Associate the assistant with the Connect instance.
  aws connect create-integration-association \
    --instance-id "$TARGET_INSTANCE_ID" \
    --integration-type WISDOM_ASSISTANT \
    --integration-arn "$new_assistant_arn" \
    --region "$TARGET_REGION" \
    --output json >/dev/null || die "Failed to associate assistant with the instance."
  ok "Associated assistant with instance (WISDOM_ASSISTANT)."

  # 3. Optionally create a knowledge base, link it to the assistant, and
  #    associate it with the Connect instance.
  if [ "$CREATE_KNOWLEDGE_BASE" = "true" ]; then
    local kb_json new_kb_arn new_kb_id
    kb_json="$(aws qconnect create-knowledge-base \
      --name "$NEW_KNOWLEDGE_BASE_NAME" \
      --knowledge-base-type CUSTOM \
      --description "Knowledge base auto-created for AI agents." \
      --region "$TARGET_REGION" \
      --output json)" || die "create-knowledge-base failed."
    new_kb_arn="$(echo "$kb_json" | jq -r '.knowledgeBase.knowledgeBaseArn')"
    new_kb_id="$(echo "$kb_json" | jq -r '.knowledgeBase.knowledgeBaseId')"
    ok "Created knowledge base '$NEW_KNOWLEDGE_BASE_NAME' -> $new_kb_id"

    aws qconnect create-assistant-association \
      --assistant-id "$new_assistant_id" \
      --association-type KNOWLEDGE_BASE \
      --association "{\"knowledgeBaseId\":\"$new_kb_id\"}" \
      --region "$TARGET_REGION" \
      --output json >/dev/null || die "Failed to link knowledge base to assistant."
    ok "Linked knowledge base to assistant."

    aws connect create-integration-association \
      --instance-id "$TARGET_INSTANCE_ID" \
      --integration-type WISDOM_KNOWLEDGE_BASE \
      --integration-arn "$new_kb_arn" \
      --region "$TARGET_REGION" \
      --output json >/dev/null || warn "Could not associate knowledge base with the instance (continuing)."
  fi

  TARGET_ASSISTANT_ARN="$new_assistant_arn"
}

if [ -z "$TARGET_ASSISTANT_ARN" ]; then
  log "Resolving Q in Connect assistant associated with the target instance..."
  TARGET_ASSISTANT_ARN="$(aws connect list-integration-associations \
    --instance-id "$TARGET_INSTANCE_ID" \
    --integration-type WISDOM_ASSISTANT \
    --region "$TARGET_REGION" \
    --query 'IntegrationAssociationSummaryList[0].IntegrationArn' \
    --output text 2>/dev/null || true)"

  if [ -z "$TARGET_ASSISTANT_ARN" ] || [ "$TARGET_ASSISTANT_ARN" = "None" ]; then
    create_qic_domain
  fi
fi
ok "Target assistant        : $TARGET_ASSISTANT_ARN"

# Derive the components needed to build AI agent entity ARNs deterministically:
#   arn:<partition>:<service>:<region>:<account>:ai-agent/<assistantId>/<agentId>:<qualifier>
# The Connect console associates security profiles against the editable "$SAVED"
# revision of the agent, so the entity ARN must carry that qualifier.
QIC_PARTITION="$(echo "$TARGET_ASSISTANT_ARN" | awk -F: '{print $2}')"
QIC_SERVICE="$(echo "$TARGET_ASSISTANT_ARN"   | awk -F: '{print $3}')"
QIC_ARN_REGION="$(echo "$TARGET_ASSISTANT_ARN" | awk -F: '{print $4}')"
QIC_ACCOUNT="$(echo "$TARGET_ASSISTANT_ARN"    | awk -F: '{print $5}')"
ASSISTANT_ID="${TARGET_ASSISTANT_ARN##*/}"

# Qualifier appended to the agent entity ARN (literal "$SAVED" by default).
AGENT_ENTITY_QUALIFIER="${AGENT_ENTITY_QUALIFIER:-}"
[ -n "$AGENT_ENTITY_QUALIFIER" ] || AGENT_ENTITY_QUALIFIER='$SAVED'

# build_agent_entity_arn <agentId> -> prints the AI agent entity ARN.
build_agent_entity_arn() {
  printf 'arn:%s:%s:%s:%s:ai-agent/%s/%s:%s' \
    "$QIC_PARTITION" "$QIC_SERVICE" "$QIC_ARN_REGION" "$QIC_ACCOUNT" "$ASSISTANT_ID" "$1" "$AGENT_ENTITY_QUALIFIER"
}

# ----------------------------------------------------------------------------
# AI Prompt: clone reference -> create in target assistant
# Echoes the new AI Prompt ID on stdout. Reuses an existing prompt with the
# same name if one is already present (idempotent reruns).
# ----------------------------------------------------------------------------
find_prompt_id_by_name() {
  aws qconnect list-ai-prompts \
    --assistant-id "$TARGET_ASSISTANT_ARN" \
    --region "$TARGET_REGION" \
    --output json 2>/dev/null \
    | jq -r --arg n "$1" \
        '.aiPromptSummaries[]? | select(.name==$n and (.aiPromptId | test(":") | not)) | .aiPromptId' \
    | head -n1
}

create_prompt_from_reference() {
  local ref_prompt_id="$1" new_name="$2"

  local existing
  existing="$(find_prompt_id_by_name "$new_name")"
  if [ -n "$existing" ]; then
    log "AI prompt \"$new_name\" already exists ($existing). Reusing." >&2
    echo "$existing"
    return 0
  fi

  log "Reading reference AI prompt $ref_prompt_id ..." >&2
  local src
  src="$(aws qconnect get-ai-prompt \
    --assistant-id "$REF_ASSISTANT_ARN" \
    --ai-prompt-id "$ref_prompt_id" \
    --region "$REF_REGION" \
    --output json)" || die "get-ai-prompt failed for $ref_prompt_id"

  local input
  input="$(jq -n --argjson src "$src" --arg assistant "$TARGET_ASSISTANT_ARN" --arg name "$new_name" '
    $src.aiPrompt as $p
    | {
        assistantId:           $assistant,
        name:                  $name,
        apiFormat:             $p.apiFormat,
        modelId:               $p.modelId,
        templateType:          $p.templateType,
        type:                  $p.type,
        visibilityStatus:      "PUBLISHED",
        templateConfiguration: $p.templateConfiguration
      }
    + (if $p.inferenceConfiguration then { inferenceConfiguration: $p.inferenceConfiguration } else {} end)
  ')"

  log "Creating AI prompt \"$new_name\" in target assistant ..." >&2
  local out
  out="$(aws qconnect create-ai-prompt \
    --region "$TARGET_REGION" \
    --cli-input-json "$input" \
    --output json)" || die "create-ai-prompt failed for $new_name"

  echo "$out" | jq -r '.aiPrompt.aiPromptId'
}

# ----------------------------------------------------------------------------
# Publish a version of an AI prompt. Echoes the qualified id <promptId>:<version>.
# ----------------------------------------------------------------------------
publish_prompt_version() {
  local prompt_id="$1"

  # Reuse an existing version if one was already published (idempotent reruns).
  local existing_ver
  existing_ver="$(aws qconnect list-ai-prompt-versions \
    --assistant-id "$TARGET_ASSISTANT_ARN" \
    --ai-prompt-id "$prompt_id" \
    --region "$TARGET_REGION" \
    --output json 2>/dev/null \
    | jq -r '[.aiPromptVersionSummaries[]?.versionNumber] | max // empty')"
  if [ -n "$existing_ver" ] && echo "$existing_ver" | grep -Eq '^[0-9]+$'; then
    log "AI prompt $prompt_id already has version $existing_ver. Reusing." >&2
    echo "${prompt_id}:${existing_ver}"
    return 0
  fi

  log "Publishing version of AI prompt $prompt_id ..." >&2
  local out
  out="$(aws qconnect create-ai-prompt-version \
    --assistant-id "$TARGET_ASSISTANT_ARN" \
    --ai-prompt-id "$prompt_id" \
    --region "$TARGET_REGION" \
    --output json)" || die "create-ai-prompt-version failed for $prompt_id"

  local version
  version="$(echo "$out" | jq -r '.versionNumber // .aiPrompt.modifiedTime // empty')"
  if [ -n "$version" ] && echo "$version" | grep -Eq '^[0-9]+$'; then
    echo "${prompt_id}:${version}"
  else
    # Fall back to the unqualified id if no numeric version was returned.
    echo "$prompt_id"
  fi
}

# ----------------------------------------------------------------------------
# AI Agent: clone reference -> filter tools -> wire to new prompt -> create.
# Echoes the new AI Agent ID on stdout. Reuses an existing agent with the same
# name if one is already present (idempotent reruns).
# ----------------------------------------------------------------------------
create_agent_from_reference() {
  local ref_agent_id="$1" new_name="$2" orchestration_prompt_id="$3"

  local existing
  existing="$(aws qconnect list-ai-agents \
    --assistant-id "$TARGET_ASSISTANT_ARN" \
    --region "$TARGET_REGION" \
    --output json 2>/dev/null \
    | jq -r --arg n "$new_name" \
        '.aiAgentSummaries[]? | select(.name==$n and (.aiAgentId | test(":") | not)) | .aiAgentId' \
    | head -n1)"
  if [ -n "$existing" ]; then
    log "AI agent \"$new_name\" already exists ($existing). Reusing." >&2
    echo "$existing"
    return 0
  fi

  log "Reading reference AI agent $ref_agent_id ..." >&2
  local src
  src="$(aws qconnect get-ai-agent \
    --assistant-id "$REF_ASSISTANT_ARN" \
    --ai-agent-id "$ref_agent_id" \
    --region "$REF_REGION" \
    --output json)" || die "get-ai-agent failed for $ref_agent_id"

  local input
  input="$(jq -n \
    --argjson src "$src" \
    --arg assistant "$TARGET_ASSISTANT_ARN" \
    --arg name "$new_name" \
    --arg instance "$TARGET_INSTANCE_ARN" \
    --arg promptId "$orchestration_prompt_id" \
    --arg guardrailId "${TARGET_GUARDRAIL_ID:-}" \
    --argjson keep "$KEEP_TOOLS" '
    $src.aiAgent as $a
    | $a.configuration.orchestrationAIAgentConfiguration as $cfg
    | {
        assistantId:      $assistant,
        name:             $name,
        type:             $a.type,
        visibilityStatus: "PUBLISHED",
        configuration: {
          orchestrationAIAgentConfiguration: (
            $cfg
            | .connectInstanceArn = $instance
            | (if $promptId != "" then .orchestrationAIPromptId = $promptId else . end)
            | (if $guardrailId != ""
                 then .orchestrationAIGuardrailId = $guardrailId
                 else del(.orchestrationAIGuardrailId) end)
            | .toolConfigurations = (
                (.toolConfigurations // [])
                | map(select(.toolName as $n | $keep | index($n)))
              )
          )
        }
      }
  ')"

  # Sanity check: ensure the agent really is an orchestration agent.
  if [ "$(echo "$input" | jq -r '.configuration.orchestrationAIAgentConfiguration // "null"')" = "null" ]; then
    die "Reference agent $ref_agent_id is not an ORCHESTRATION agent; cannot filter tools."
  fi

  log "Creating AI agent \"$new_name\" (tools: Complete, Escalate) ..." >&2
  local out
  out="$(aws qconnect create-ai-agent \
    --region "$TARGET_REGION" \
    --cli-input-json "$input" \
    --output json)" || die "create-ai-agent failed for $new_name"

  echo "$out" | jq -r '.aiAgent.aiAgentId'
}

# ============================================================================
# 1. AI Prompts
# ============================================================================
log "=== Creating AI Prompts ==="
VOICE_PROMPT_ID="$(create_prompt_from_reference "$REF_VOICE_PROMPT_ID" "$VOICE_PROMPT_NAME")"
ok "Created $VOICE_PROMPT_NAME -> $VOICE_PROMPT_ID"

CHAT_PROMPT_ID="$(create_prompt_from_reference "$REF_CHAT_PROMPT_ID" "$CHAT_PROMPT_NAME")"
ok "Created $CHAT_PROMPT_NAME -> $CHAT_PROMPT_ID"

# Publish versions so the prompts can be referenced by the agents at runtime.
VOICE_PROMPT_QUALIFIED="$(publish_prompt_version "$VOICE_PROMPT_ID")"
ok "Published voice prompt version -> $VOICE_PROMPT_QUALIFIED"

CHAT_PROMPT_QUALIFIED="$(publish_prompt_version "$CHAT_PROMPT_ID")"
ok "Published chat prompt version  -> $CHAT_PROMPT_QUALIFIED"

# ============================================================================
# 2. AI Agents (tools limited to Complete + Escalate)
# ============================================================================
log "=== Creating AI Agents ==="
VOICE_AGENT_ID="$(create_agent_from_reference "$REF_VOICE_AGENT_ID" "$VOICE_AGENT_NAME" "$VOICE_PROMPT_QUALIFIED")"
ok "Created $VOICE_AGENT_NAME -> $VOICE_AGENT_ID"

CHAT_AGENT_ID="$(create_agent_from_reference "$REF_CHAT_AGENT_ID" "$CHAT_AGENT_NAME" "$CHAT_PROMPT_QUALIFIED")"
ok "Created $CHAT_AGENT_NAME -> $CHAT_AGENT_ID"

# ============================================================================
# 3. Security Profile
# ============================================================================
log "=== Creating Security Profile ==="
SECURITY_PROFILE_ID="$(aws connect list-security-profiles \
  --instance-id "$TARGET_INSTANCE_ID" \
  --region "$TARGET_REGION" \
  --query "SecurityProfileSummaryList[?Name=='${SECURITY_PROFILE_NAME}'].Id | [0]" \
  --output text 2>/dev/null || true)"

if [ -n "$SECURITY_PROFILE_ID" ] && [ "$SECURITY_PROFILE_ID" != "None" ]; then
  warn "Security profile '$SECURITY_PROFILE_NAME' already exists (Id: $SECURITY_PROFILE_ID). Reusing."
else
  SECURITY_PROFILE_ID="$(aws connect create-security-profile \
    --instance-id "$TARGET_INSTANCE_ID" \
    --security-profile-name "$SECURITY_PROFILE_NAME" \
    --description "Access to Amazon Q in Connect AI agent designer resources." \
    --region "$TARGET_REGION" \
    --query 'SecurityProfileId' \
    --output text)" || die "create-security-profile failed for $SECURITY_PROFILE_NAME"
  ok "Created security profile '$SECURITY_PROFILE_NAME' -> $SECURITY_PROFILE_ID"
fi

# ============================================================================
# 4. Associate the security profile with each AI agent (EntityType AI_AGENT)
# ============================================================================
# Called directly over the Connect REST endpoint with SigV4:
#   POST /associate-security-profiles/{InstanceId}
# This works on any AWS CLI version (the --entity-type option exists only on very
# recent builds) and binds the profile to the agent's editable "$SAVED" revision,
# exactly as the Connect console does.
log "=== Associating security profile with AI agents ==="

[ -n "$SECURITY_PROFILE_ID" ] && [ "$SECURITY_PROFILE_ID" != "None" ] \
  || die "Security profile id is empty; cannot associate with AI agents."
command -v curl >/dev/null 2>&1 || die "curl is required to associate security profiles."
curl --help all 2>/dev/null | grep -q -- '--aws-sigv4' \
  || die "Your curl lacks --aws-sigv4 (needs curl >= 7.75). Upgrade curl and re-run."

# Resolve concrete credentials from whatever the CLI is configured to use.
_creds="$(aws configure export-credentials --format env-no-export 2>/dev/null || true)"
AWS_AK="$(printf '%s\n' "$_creds" | sed -n 's/^AWS_ACCESS_KEY_ID=//p')";     AWS_AK="${AWS_AK:-${AWS_ACCESS_KEY_ID:-}}"
AWS_SK="$(printf '%s\n' "$_creds" | sed -n 's/^AWS_SECRET_ACCESS_KEY=//p')"; AWS_SK="${AWS_SK:-${AWS_SECRET_ACCESS_KEY:-}}"
AWS_ST="$(printf '%s\n' "$_creds" | sed -n 's/^AWS_SESSION_TOKEN=//p')";     AWS_ST="${AWS_ST:-${AWS_SESSION_TOKEN:-}}"
[ -n "$AWS_AK" ] && [ -n "$AWS_SK" ] || die "Could not resolve AWS credentials."

associate_sp_with_agent() {
  local agent_name="$1" agent_id="$2" entity_arn body resp code payload
  entity_arn="$(build_agent_entity_arn "$agent_id")"
  log "Associating SP $SECURITY_PROFILE_ID with $agent_name ($entity_arn)" >&2

  body="$(jq -n --arg arn "$entity_arn" --arg sp "$SECURITY_PROFILE_ID" \
    '{EntityArn:$arn, EntityType:"AI_AGENT", SecurityProfiles:[{Id:$sp}]}')"

  local args=(
    -sS -X POST
    "https://connect.${TARGET_REGION}.amazonaws.com/associate-security-profiles/${TARGET_INSTANCE_ID}"
    --aws-sigv4 "aws:amz:${TARGET_REGION}:connect"
    --user "${AWS_AK}:${AWS_SK}"
    -H "Content-Type: application/json"
  )
  [ -n "$AWS_ST" ] && args+=( -H "x-amz-security-token: ${AWS_ST}" )
  args+=( -d "$body" -w $'\n%{http_code}' )

  resp="$(curl "${args[@]}")" || die "curl request failed for $agent_name."
  code="$(printf '%s' "$resp" | tail -n1)"
  payload="$(printf '%s' "$resp" | sed '$d')"
  case "$code" in
    2*)  ok "Associated '$SECURITY_PROFILE_NAME' with $agent_name" ;;
    409) ok "'$SECURITY_PROFILE_NAME' already associated with $agent_name" ;;
    *)   die "Associate failed for $agent_name (HTTP $code): $payload" ;;
  esac
}
associate_sp_with_agent "$VOICE_AGENT_NAME" "$VOICE_AGENT_ID"
associate_sp_with_agent "$CHAT_AGENT_NAME" "$CHAT_AGENT_ID"

# ============================================================================
# Summary
# ============================================================================
echo
ok "All resources provisioned successfully:"
printf '  %-38s %s\n' "$VOICE_PROMPT_NAME" "$VOICE_PROMPT_ID"
printf '  %-38s %s\n' "$CHAT_PROMPT_NAME"  "$CHAT_PROMPT_ID"
printf '  %-38s %s\n' "$VOICE_AGENT_NAME"  "$VOICE_AGENT_ID"
printf '  %-38s %s\n' "$CHAT_AGENT_NAME"   "$CHAT_AGENT_ID"
printf '  %-38s %s\n' "$SECURITY_PROFILE_NAME" "$SECURITY_PROFILE_ID"
echo
ok "Security profile '$SECURITY_PROFILE_NAME' associated with both AI agents."
