#!/usr/bin/env bash
#
# create_connect_ai_agents.sh
#
# Provisions Amazon Q in Connect resources for a target Amazon Connect instance:
#   - 2 AI Prompts : SelfServiceOrchestrationVoice_Prompt, SelfServiceOrchestrationChat_Prompt
#   - 2 AI Agents  : SelfServiceOrchestrator_Voice_Agent, SelfServiceOrchestrator_Chat_Agent
#                    (tools reduced to only "Complete" and "Escalate")
#   - 1 Security Profile : AI-Agent (associated with both AI agents)
#   - 1 Lambda     : ConnectAssistantUpdateSessionData (deployed + associated)
#   - 1 Contact flow imported from "AI Agent - MCP Inbound Flow.json", re-pointed
#     at the target assistant/agents/Lambda/Lex bot/queue. CHAT uses the Chat
#     agent and VOICE uses the Voice agent, both at version $LATEST.
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
# read the reference assistant and write to the target instance's assistant,
# create/associate security profiles, deploy/associate the Lambda (and create an
# IAM role unless LAMBDA_ROLE_ARN is supplied), and import contact flows.
#
# Usage:
#   ./create_connect_ai_agents.sh [TARGET_CONNECT_INSTANCE_ARN] [TARGET_ASSISTANT_ARN]
#
# The script prompts for the Connect instance ARN (if not given) and the Lex bot
# ARN (TestBotAlias is used). The Lex ARN can also be supplied via LEX_BOT_ARN.
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

# Q in Connect "domain" (assistant) settings used only when the target instance
# has no assistant yet. The name is prompted for at runtime (or supplied via
# NEW_ASSISTANT_NAME). This exact name is not allowed.
NEW_ASSISTANT_NAME="${NEW_ASSISTANT_NAME:-}"
FORBIDDEN_ASSISTANT_NAME="SelfServiceOrchestrator_Voice-Assistant"
NEW_KNOWLEDGE_BASE_NAME="${NEW_KNOWLEDGE_BASE_NAME:-}"
# Set CREATE_KNOWLEDGE_BASE=false to only create+associate the assistant.
CREATE_KNOWLEDGE_BASE="${CREATE_KNOWLEDGE_BASE:-true}"

# Tools to keep on the AI agents.
KEEP_TOOLS='["Complete","Escalate"]'

# ----------------------------------------------------------------------------
# Contact flow import configuration. Override via environment variables.
# ----------------------------------------------------------------------------
FLOW_JSON_FILE="${FLOW_JSON_FILE:-AI Agent - MCP Inbound Flow.json}"
FLOW_NAME="${FLOW_NAME:-AI Agent - MCP Inbound Flow}"
FLOW_TYPE="${FLOW_TYPE:-CONTACT_FLOW}"

# Values rewritten inside the flow's Lambda invocation attributes.
FLOW_NEW_PHONE="${FLOW_NEW_PHONE:-12345678900}"
FLOW_NEW_BU="${FLOW_NEW_BU:-US}"

LAMBDA_FUNCTION_NAME="${LAMBDA_FUNCTION_NAME:-ConnectAssistantUpdateSessionData}"
LAMBDA_ZIP_FILE="${LAMBDA_ZIP_FILE:-ConnectAssistantUpdateSessionData-dbcd9ed4-0218-4522-adff-b9850c8b80eb.zip}"
LAMBDA_RUNTIME="${LAMBDA_RUNTIME:-nodejs20.x}"
LAMBDA_HANDLER="${LAMBDA_HANDLER:-index.handler}"
LAMBDA_TIMEOUT="${LAMBDA_TIMEOUT:-15}"
# Optional: pre-existing execution role ARN. If empty a role is created.
LAMBDA_ROLE_ARN="${LAMBDA_ROLE_ARN:-}"
LAMBDA_ROLE_NAME="${LAMBDA_ROLE_NAME:-${LAMBDA_FUNCTION_NAME}-role}"

# Lex V2 "TestBotAlias" always has this fixed alias id.
LEX_TEST_ALIAS_ID="TSTALIASID"

# Queue name to bind the flow's transfer step to in the target instance.
TARGET_QUEUE_NAME="${TARGET_QUEUE_NAME:-BasicQueue}"

# Literal values in the template flow JSON that must be re-pointed at the target.
FLOW_OLD_ASSISTANT_ARN="arn:aws:wisdom:us-west-2:991727053196:assistant/14fe4db3-cca0-4c91-b484-ee7dc6a0e9aa"
FLOW_OLD_CHAT_AGENT_ARN="arn:aws:wisdom:us-west-2:991727053196:ai-agent/14fe4db3-cca0-4c91-b484-ee7dc6a0e9aa/f01b8be1-b98b-40b9-b942-3ffc62c14e57:\$LATEST"
FLOW_OLD_VOICE_AGENT_ARN="arn:aws:wisdom:us-west-2:991727053196:ai-agent/14fe4db3-cca0-4c91-b484-ee7dc6a0e9aa/1ad99f3e-e69c-4477-b45e-36b8b56a0449:\$LATEST"
FLOW_OLD_LAMBDA_ARN="arn:aws:lambda:us-west-2:991727053196:function:ConnectAssistantUpdateSessionData"
FLOW_OLD_LEX_ALIAS_ARN="arn:aws:lex:us-west-2:991727053196:bot-alias/W0MUSVSUH1/TSTALIASID"
FLOW_OLD_QUEUE_ARN="arn:aws:connect:us-west-2:991727053196:instance/2ff5674e-de94-4714-bc6d-d7f2cebeee9d/queue/40bfd421-818e-4c35-809d-f5bcd94f1493"
FLOW_OLD_CHAT_AGENT_NAME="SelfServiceOrchestrator_Chat_0519 "
FLOW_OLD_VOICE_AGENT_NAME="SelfServiceOrchestrator_0519  "
FLOW_OLD_LEX_BOT_NAME="NovaSonicSupport_2025_Bot"
FLOW_OLD_NAME="AI Agent - MCP"
FLOW_OLD_PHONE="18618383641"
FLOW_OLD_BU="US"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
log()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m  %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[FAIL]\033[0m  %s\n' "$*" >&2; exit 1; }

# region_from_arn <arn>  ->  prints the region segment (4th field)
region_from_arn() { echo "$1" | awk -F: '{print $4}'; }

# build_lex_alias_arn <lex bot or alias ARN> -> prints the TestBotAlias ARN.
# Accepts either a bot ARN (.../bot/<id>) or a bot-alias ARN, and always targets
# the fixed TestBotAlias id (TSTALIASID).
build_lex_alias_arn() {
  local input="$1" base botid
  case "$input" in
    *:bot-alias/*)
      base="${input%%:bot-alias/*}"
      botid="${input##*:bot-alias/}"; botid="${botid%%/*}"
      printf '%s:bot-alias/%s/%s' "$base" "$botid" "$LEX_TEST_ALIAS_ID" ;;
    *:bot/*)
      base="${input%%:bot/*}"
      botid="${input##*:bot/}"; botid="${botid%%/*}"
      printf '%s:bot-alias/%s/%s' "$base" "$botid" "$LEX_TEST_ALIAS_ID" ;;
    *)
      die "无法识别的 Lex ARN '$input'（应为 arn:aws:lex:<region>:<acct>:bot/<id> 或 :bot-alias/<id>/<alias>）。" ;;
  esac
}

# ----------------------------------------------------------------------------
# Argument & dependency validation
# ----------------------------------------------------------------------------
command -v aws >/dev/null 2>&1 || die "未找到 aws CLI，请安装 AWS CLI v2。"
command -v jq  >/dev/null 2>&1 || die "未找到 jq，请安装 jq（例如 'brew install jq'）。"

TARGET_INSTANCE_ARN="${1:-}"
TARGET_ASSISTANT_ARN="${2:-}"

# Prompt for the target Connect instance ARN if it was not supplied.
if [ -z "$TARGET_INSTANCE_ARN" ]; then
  printf '请输入目标 Amazon Connect 实例 ARN: '
  read -r TARGET_INSTANCE_ARN
  [ -n "$TARGET_INSTANCE_ARN" ] || die "未提供 Connect 实例 ARN。"
fi

case "$TARGET_INSTANCE_ARN" in
  arn:aws:connect:*:*:instance/*) : ;;
  *) die "第一个参数必须是 Connect 实例 ARN（arn:aws:connect:<region>:<acct>:instance/<id>）。" ;;
esac

# Prompt for the Lex bot ARN (used to replace the flow's Lex bot, alias TestBotAlias).
LEX_BOT_ARN="${LEX_BOT_ARN:-}"
if [ -z "$LEX_BOT_ARN" ]; then
  printf '请输入 Lex 机器人 ARN（将使用 TestBotAlias）: '
  read -r LEX_BOT_ARN
  [ -n "$LEX_BOT_ARN" ] || die "未提供 Lex 机器人 ARN。"
fi
LEX_ALIAS_ARN="$(build_lex_alias_arn "$LEX_BOT_ARN")"

TARGET_INSTANCE_ID="${TARGET_INSTANCE_ARN##*/}"
TARGET_REGION="$(region_from_arn "$TARGET_INSTANCE_ARN")"
TARGET_ACCOUNT="$(echo "$TARGET_INSTANCE_ARN" | awk -F: '{print $5}')"
REF_REGION="$(region_from_arn "$REF_ASSISTANT_ARN")"

log "目标 Connect 实例     : $TARGET_INSTANCE_ARN"
log "目标实例 ID           : $TARGET_INSTANCE_ID"
log "目标区域              : $TARGET_REGION"
log "Lex 别名(TestBotAlias): $LEX_ALIAS_ARN"
log "参考 assistant        : $REF_ASSISTANT_ARN ($REF_REGION)"

# ----------------------------------------------------------------------------
# Resolve (or create) the target Q in Connect assistant ("domain")
# ----------------------------------------------------------------------------

# resolve_domain_name : ensures NEW_ASSISTANT_NAME is set to a valid, non-empty
# name that is not the forbidden one (prompting interactively if needed).
resolve_domain_name() {
  while :; do
    if [ -z "$NEW_ASSISTANT_NAME" ]; then
      printf '请输入 Q in Connect domain（assistant）的名称: '
      read -r NEW_ASSISTANT_NAME
    fi
    if [ -z "$NEW_ASSISTANT_NAME" ]; then
      warn "domain 名称不能为空。"
      continue
    fi
    if [ "$NEW_ASSISTANT_NAME" = "$FORBIDDEN_ASSISTANT_NAME" ]; then
      warn "名称 '$FORBIDDEN_ASSISTANT_NAME' 不允许使用，请换一个。"
      NEW_ASSISTANT_NAME=""
      [ -t 0 ] && continue || die "拒绝使用被禁止的 domain 名称 '$FORBIDDEN_ASSISTANT_NAME'。"
    fi
    break
  done
}

# create_qic_domain : resolves the Q in Connect assistant ("domain") for the
# instance. Prompts for a name, reuses an existing assistant with that name if
# one exists, otherwise creates a new assistant (+ optional knowledge base).
# Associates the assistant with the Connect instance and sets TARGET_ASSISTANT_ARN.
create_qic_domain() {
  log "实例没有关联任何 assistant，正在解析 Q in Connect domain..."
  resolve_domain_name

  local new_assistant_arn new_assistant_id existing_arn
  existing_arn="$(aws qconnect list-assistants \
    --region "$TARGET_REGION" --output json 2>/dev/null \
    | jq -r --arg n "$NEW_ASSISTANT_NAME" \
        'first(.assistantSummaries[]? | select(.name==$n) | .assistantArn) // empty')"

  if [ -n "$existing_arn" ]; then
    new_assistant_arn="$existing_arn"
    new_assistant_id="${new_assistant_arn##*/}"
    ok "找到已存在的 domain '$NEW_ASSISTANT_NAME' -> ${new_assistant_id}（复用）。"
    # Make sure it is associated with this Connect instance.
    aws connect create-integration-association \
      --instance-id "$TARGET_INSTANCE_ID" \
      --integration-type WISDOM_ASSISTANT \
      --integration-arn "$new_assistant_arn" \
      --region "$TARGET_REGION" \
      --output json >/dev/null 2>&1 \
      && ok "已将现有 assistant 关联到实例（WISDOM_ASSISTANT）。" \
      || log "assistant 已关联到实例（继续）。" >&2
    TARGET_ASSISTANT_ARN="$new_assistant_arn"
    return 0
  fi

  log "不存在名为 '$NEW_ASSISTANT_NAME' 的 domain，正在创建新的..."

  # 1. Assistant
  local assistant_json
  assistant_json="$(aws qconnect create-assistant \
    --name "$NEW_ASSISTANT_NAME" \
    --type AGENT \
    --description "Q in Connect assistant created for AI agents." \
    --region "$TARGET_REGION" \
    --output json)" || die "create-assistant 失败。"
  new_assistant_arn="$(echo "$assistant_json" | jq -r '.assistant.assistantArn')"
  new_assistant_id="$(echo "$assistant_json" | jq -r '.assistant.assistantId')"
  ok "已创建 assistant '$NEW_ASSISTANT_NAME' -> $new_assistant_id"

  # 2. Associate the assistant with the Connect instance.
  aws connect create-integration-association \
    --instance-id "$TARGET_INSTANCE_ID" \
    --integration-type WISDOM_ASSISTANT \
    --integration-arn "$new_assistant_arn" \
    --region "$TARGET_REGION" \
    --output json >/dev/null || die "将 assistant 关联到实例失败。"
  ok "已将 assistant 关联到实例（WISDOM_ASSISTANT）。"

  # 3. Optionally create a knowledge base, link it to the assistant, and
  #    associate it with the Connect instance.
  if [ "$CREATE_KNOWLEDGE_BASE" = "true" ]; then
    local kb_name kb_json new_kb_arn new_kb_id
    kb_name="${NEW_KNOWLEDGE_BASE_NAME:-${NEW_ASSISTANT_NAME}-KnowledgeBase}"
    kb_json="$(aws qconnect create-knowledge-base \
      --name "$kb_name" \
      --knowledge-base-type CUSTOM \
      --description "Knowledge base created for AI agents." \
      --region "$TARGET_REGION" \
      --output json)" || die "create-knowledge-base 失败。"
    new_kb_arn="$(echo "$kb_json" | jq -r '.knowledgeBase.knowledgeBaseArn')"
    new_kb_id="$(echo "$kb_json" | jq -r '.knowledgeBase.knowledgeBaseId')"
    ok "已创建知识库 '$kb_name' -> $new_kb_id"

    aws qconnect create-assistant-association \
      --assistant-id "$new_assistant_id" \
      --association-type KNOWLEDGE_BASE \
      --association "{\"knowledgeBaseId\":\"$new_kb_id\"}" \
      --region "$TARGET_REGION" \
      --output json >/dev/null || die "将知识库关联到 assistant 失败。"
    ok "已将知识库关联到 assistant。"

    aws connect create-integration-association \
      --instance-id "$TARGET_INSTANCE_ID" \
      --integration-type WISDOM_KNOWLEDGE_BASE \
      --integration-arn "$new_kb_arn" \
      --region "$TARGET_REGION" \
      --output json >/dev/null || warn "无法将知识库关联到实例（继续）。"
  fi

  TARGET_ASSISTANT_ARN="$new_assistant_arn"
}

if [ -z "$TARGET_ASSISTANT_ARN" ]; then
  log "正在查找与目标实例关联的 Q in Connect assistant..."
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
ok "目标 assistant        : $TARGET_ASSISTANT_ARN"

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
    log "AI prompt \"$new_name\" 已存在 ($existing)，复用。" >&2
    echo "$existing"
    return 0
  fi

  log "正在读取参考 AI prompt $ref_prompt_id ..." >&2
  local src
  src="$(aws qconnect get-ai-prompt \
    --assistant-id "$REF_ASSISTANT_ARN" \
    --ai-prompt-id "$ref_prompt_id" \
    --region "$REF_REGION" \
    --output json)" || die "get-ai-prompt 失败：$ref_prompt_id"

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

  log "正在目标 assistant 中创建 AI prompt \"$new_name\" ..." >&2
  local out
  out="$(aws qconnect create-ai-prompt \
    --region "$TARGET_REGION" \
    --cli-input-json "$input" \
    --output json)" || die "create-ai-prompt 失败：$new_name"

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
    log "AI prompt $prompt_id 已有版本 ${existing_ver}，复用。" >&2
    echo "${prompt_id}:${existing_ver}"
    return 0
  fi

  log "正在发布 AI prompt $prompt_id 的版本 ..." >&2
  local out
  out="$(aws qconnect create-ai-prompt-version \
    --assistant-id "$TARGET_ASSISTANT_ARN" \
    --ai-prompt-id "$prompt_id" \
    --region "$TARGET_REGION" \
    --output json)" || die "create-ai-prompt-version 失败：$prompt_id"

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
    log "AI agent \"$new_name\" 已存在 ($existing)，复用。" >&2
    echo "$existing"
    return 0
  fi

  log "正在读取参考 AI agent $ref_agent_id ..." >&2
  local src
  src="$(aws qconnect get-ai-agent \
    --assistant-id "$REF_ASSISTANT_ARN" \
    --ai-agent-id "$ref_agent_id" \
    --region "$REF_REGION" \
    --output json)" || die "get-ai-agent 失败：$ref_agent_id"

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
    die "参考 agent $ref_agent_id 不是 ORCHESTRATION 类型，无法筛选工具。"
  fi

  log "正在创建 AI agent \"$new_name\"（工具：Complete、Escalate）..." >&2
  local out
  out="$(aws qconnect create-ai-agent \
    --region "$TARGET_REGION" \
    --cli-input-json "$input" \
    --output json)" || die "create-ai-agent 失败：$new_name"

  echo "$out" | jq -r '.aiAgent.aiAgentId'
}

# ============================================================================
# 1. AI Prompts
# ============================================================================
log "=== 创建 AI Prompts ==="
VOICE_PROMPT_ID="$(create_prompt_from_reference "$REF_VOICE_PROMPT_ID" "$VOICE_PROMPT_NAME")"
ok "已创建 $VOICE_PROMPT_NAME -> $VOICE_PROMPT_ID"

CHAT_PROMPT_ID="$(create_prompt_from_reference "$REF_CHAT_PROMPT_ID" "$CHAT_PROMPT_NAME")"
ok "已创建 $CHAT_PROMPT_NAME -> $CHAT_PROMPT_ID"

# Publish versions so the prompts can be referenced by the agents at runtime.
VOICE_PROMPT_QUALIFIED="$(publish_prompt_version "$VOICE_PROMPT_ID")"
ok "已发布语音 prompt 版本 -> $VOICE_PROMPT_QUALIFIED"

CHAT_PROMPT_QUALIFIED="$(publish_prompt_version "$CHAT_PROMPT_ID")"
ok "已发布聊天 prompt 版本 -> $CHAT_PROMPT_QUALIFIED"

# ============================================================================
# 2. AI Agents (tools limited to Complete + Escalate)
# ============================================================================
log "=== 创建 AI Agents ==="
VOICE_AGENT_ID="$(create_agent_from_reference "$REF_VOICE_AGENT_ID" "$VOICE_AGENT_NAME" "$VOICE_PROMPT_QUALIFIED")"
ok "已创建 $VOICE_AGENT_NAME -> $VOICE_AGENT_ID"

CHAT_AGENT_ID="$(create_agent_from_reference "$REF_CHAT_AGENT_ID" "$CHAT_AGENT_NAME" "$CHAT_PROMPT_QUALIFIED")"
ok "已创建 $CHAT_AGENT_NAME -> $CHAT_AGENT_ID"

# ============================================================================
# 3. Security Profile
# ============================================================================
log "=== 创建安全配置文件（Security Profile）==="
SECURITY_PROFILE_ID="$(aws connect list-security-profiles \
  --instance-id "$TARGET_INSTANCE_ID" \
  --region "$TARGET_REGION" \
  --query "SecurityProfileSummaryList[?Name=='${SECURITY_PROFILE_NAME}'].Id | [0]" \
  --output text 2>/dev/null || true)"

if [ -n "$SECURITY_PROFILE_ID" ] && [ "$SECURITY_PROFILE_ID" != "None" ]; then
  warn "安全配置文件 '$SECURITY_PROFILE_NAME' 已存在 (Id: $SECURITY_PROFILE_ID)，复用。"
else
  SECURITY_PROFILE_ID="$(aws connect create-security-profile \
    --instance-id "$TARGET_INSTANCE_ID" \
    --security-profile-name "$SECURITY_PROFILE_NAME" \
    --description "Access to Amazon Q in Connect AI agent designer resources." \
    --region "$TARGET_REGION" \
    --query 'SecurityProfileId' \
    --output text)" || die "create-security-profile 失败：$SECURITY_PROFILE_NAME"
  ok "已创建安全配置文件 '$SECURITY_PROFILE_NAME' -> $SECURITY_PROFILE_ID"
fi

# ============================================================================
# 4. Associate the security profile with each AI agent (EntityType AI_AGENT)
# ============================================================================
# Called directly over the Connect REST endpoint with SigV4:
#   POST /associate-security-profiles/{InstanceId}
# This works on any AWS CLI version (the --entity-type option exists only on very
# recent builds) and binds the profile to the agent's editable "$SAVED" revision,
# exactly as the Connect console does.
log "=== 将安全配置文件关联到 AI agents ==="

[ -n "$SECURITY_PROFILE_ID" ] && [ "$SECURITY_PROFILE_ID" != "None" ] \
  || die "安全配置文件 ID 为空，无法关联到 AI agents。"
command -v curl >/dev/null 2>&1 || die "关联安全配置文件需要 curl。"
curl --help all 2>/dev/null | grep -q -- '--aws-sigv4' \
  || die "你的 curl 不支持 --aws-sigv4（需要 curl >= 7.75），请升级 curl 后重试。"

# Resolve concrete credentials from whatever the CLI is configured to use.
_creds="$(aws configure export-credentials --format env-no-export 2>/dev/null || true)"
AWS_AK="$(printf '%s\n' "$_creds" | sed -n 's/^AWS_ACCESS_KEY_ID=//p')";     AWS_AK="${AWS_AK:-${AWS_ACCESS_KEY_ID:-}}"
AWS_SK="$(printf '%s\n' "$_creds" | sed -n 's/^AWS_SECRET_ACCESS_KEY=//p')"; AWS_SK="${AWS_SK:-${AWS_SECRET_ACCESS_KEY:-}}"
AWS_ST="$(printf '%s\n' "$_creds" | sed -n 's/^AWS_SESSION_TOKEN=//p')";     AWS_ST="${AWS_ST:-${AWS_SESSION_TOKEN:-}}"
[ -n "$AWS_AK" ] && [ -n "$AWS_SK" ] || die "无法获取 AWS 凭证。"

associate_sp_with_agent() {
  local agent_name="$1" agent_id="$2" entity_arn body resp code payload
  entity_arn="$(build_agent_entity_arn "$agent_id")"
  log "正在将安全配置文件 $SECURITY_PROFILE_ID 关联到 $agent_name ($entity_arn)" >&2

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

  resp="$(curl "${args[@]}")" || die "$agent_name 的 curl 请求失败。"
  code="$(printf '%s' "$resp" | tail -n1)"
  payload="$(printf '%s' "$resp" | sed '$d')"
  case "$code" in
    2*)  ok "已将 '$SECURITY_PROFILE_NAME' 关联到 $agent_name" ;;
    409) ok "'$SECURITY_PROFILE_NAME' 已关联到 $agent_name" ;;
    *)   die "$agent_name 关联失败 (HTTP $code): $payload" ;;
  esac
}
associate_sp_with_agent "$VOICE_AGENT_NAME" "$VOICE_AGENT_ID"
associate_sp_with_agent "$CHAT_AGENT_NAME" "$CHAT_AGENT_ID"

# ============================================================================
# 5. Deploy the ConnectAssistantUpdateSessionData Lambda + associate with instance
# ============================================================================
log "=== 部署 Lambda $LAMBDA_FUNCTION_NAME ==="
[ -f "$LAMBDA_ZIP_FILE" ] || die "未找到 Lambda zip 文件：$LAMBDA_ZIP_FILE"

# ensure_lambda_role : returns an execution role ARN, creating one if needed.
ensure_lambda_role() {
  local arn
  arn="$(aws iam get-role --role-name "$LAMBDA_ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null || true)"
  if [ -n "$arn" ] && [ "$arn" != "None" ]; then echo "$arn"; return 0; fi

  log "正在创建 Lambda 执行角色 '$LAMBDA_ROLE_NAME' ..." >&2
  local trust='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
  arn="$(aws iam create-role --role-name "$LAMBDA_ROLE_NAME" \
    --assume-role-policy-document "$trust" \
    --query 'Role.Arn' --output text)" || die "create-role 失败：$LAMBDA_ROLE_NAME"
  aws iam attach-role-policy --role-name "$LAMBDA_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole >/dev/null \
    || warn "无法附加 AWSLambdaBasicExecutionRole。"
  sleep 12   # wait for IAM role propagation
  echo "$arn"
}

LAMBDA_ENV="Variables={AI_ASSISTANT_ID=${ASSISTANT_ID},CONNECT_INSTANCE_ID=${TARGET_INSTANCE_ID}}"

if aws lambda get-function --function-name "$LAMBDA_FUNCTION_NAME" --region "$TARGET_REGION" >/dev/null 2>&1; then
  log "Lambda 已存在，正在更新代码与配置。" >&2
  aws lambda update-function-code \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --zip-file "fileb://$LAMBDA_ZIP_FILE" \
    --region "$TARGET_REGION" --output json >/dev/null || die "update-function-code 失败。"
  aws lambda wait function-updated \
    --function-name "$LAMBDA_FUNCTION_NAME" --region "$TARGET_REGION" 2>/dev/null || true
  aws lambda update-function-configuration \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --environment "$LAMBDA_ENV" \
    --region "$TARGET_REGION" --output json >/dev/null || die "update-function-configuration 失败。"
else
  [ -n "$LAMBDA_ROLE_ARN" ] || LAMBDA_ROLE_ARN="$(ensure_lambda_role)"
  aws lambda create-function \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --runtime "$LAMBDA_RUNTIME" \
    --handler "$LAMBDA_HANDLER" \
    --role "$LAMBDA_ROLE_ARN" \
    --timeout "$LAMBDA_TIMEOUT" \
    --environment "$LAMBDA_ENV" \
    --zip-file "fileb://$LAMBDA_ZIP_FILE" \
    --region "$TARGET_REGION" --output json >/dev/null || die "create-function 失败。"
fi
aws lambda wait function-updated \
  --function-name "$LAMBDA_FUNCTION_NAME" --region "$TARGET_REGION" 2>/dev/null || true
LAMBDA_ARN="arn:aws:lambda:${TARGET_REGION}:${TARGET_ACCOUNT}:function:${LAMBDA_FUNCTION_NAME}"
ok "Lambda 就绪 -> $LAMBDA_ARN (AI_ASSISTANT_ID=$ASSISTANT_ID, CONNECT_INSTANCE_ID=$TARGET_INSTANCE_ID)"

# Ensure the function's ACTUAL execution role has the runtime permissions it needs
# (connect:DescribeContact + qconnect/wisdom:UpdateSessionData). This covers a
# pre-existing function whose role we did not create.
LAMBDA_ROLE_IN_USE="$(aws lambda get-function \
  --function-name "$LAMBDA_FUNCTION_NAME" --region "$TARGET_REGION" \
  --query 'Configuration.Role' --output text 2>/dev/null || true)"
if [ -n "$LAMBDA_ROLE_IN_USE" ] && [ "$LAMBDA_ROLE_IN_USE" != "None" ]; then
  LAMBDA_ROLE_IN_USE_NAME="${LAMBDA_ROLE_IN_USE##*/}"
  LAMBDA_RUNTIME_POLICY="$(jq -n \
    --arg contacts "arn:aws:connect:${TARGET_REGION}:${TARGET_ACCOUNT}:instance/${TARGET_INSTANCE_ID}/contact/*" \
    --arg assistant "$TARGET_ASSISTANT_ARN" \
    --arg sessions "arn:${QIC_PARTITION}:${QIC_SERVICE}:${QIC_ARN_REGION}:${QIC_ACCOUNT}:session/${ASSISTANT_ID}/*" '
    {Version:"2012-10-17",Statement:[
      {Effect:"Allow",Action:["connect:DescribeContact"],Resource:$contacts},
      {Effect:"Allow",Action:["wisdom:UpdateSessionData","wisdom:GetSession"],Resource:[$assistant,$sessions]}
    ]}')"
  aws iam put-role-policy \
    --role-name "$LAMBDA_ROLE_IN_USE_NAME" \
    --policy-name "ConnectAssistant-runtime-${TARGET_INSTANCE_ID}" \
    --policy-document "$LAMBDA_RUNTIME_POLICY" >/dev/null 2>&1 \
    && ok "已为 Lambda 角色 '$LAMBDA_ROLE_IN_USE_NAME' 授予 connect:DescribeContact + UpdateSessionData。" \
    || warn "无法为 Lambda 角色 '$LAMBDA_ROLE_IN_USE_NAME' 附加运行时策略（请检查 IAM 权限）。"
else
  warn "无法获取 Lambda 执行角色，运行时权限未验证。"
fi

# Allow Amazon Connect to invoke the function, and add it to the instance.
aws lambda add-permission \
  --function-name "$LAMBDA_FUNCTION_NAME" \
  --statement-id "AmazonConnect-${TARGET_INSTANCE_ID}" \
  --action lambda:InvokeFunction \
  --principal connect.amazonaws.com \
  --source-arn "$TARGET_INSTANCE_ARN" \
  --region "$TARGET_REGION" >/dev/null 2>&1 \
  || log "Lambda 调用权限已存在（继续）。" >&2

aws connect associate-lambda-function \
  --instance-id "$TARGET_INSTANCE_ID" \
  --function-arn "$LAMBDA_ARN" \
  --region "$TARGET_REGION" >/dev/null 2>&1 \
  && ok "已将 Lambda 关联到实例。" \
  || log "Lambda 已关联到实例（继续）。" >&2

# ============================================================================
# 6. Import the contact flow (re-pointed at the target resources)
# ============================================================================
log "=== 导入 contact flow '$FLOW_NAME' ==="
[ -f "$FLOW_JSON_FILE" ] || die "未找到 flow JSON 文件：$FLOW_JSON_FILE"

# Associate the Lex bot (TestBotAlias) so the flow can reference it.
aws connect associate-bot \
  --instance-id "$TARGET_INSTANCE_ID" \
  --lex-v2-bot "AliasArn=$LEX_ALIAS_ARN" \
  --region "$TARGET_REGION" >/dev/null 2>&1 \
  && ok "已将 Lex 机器人（TestBotAlias）关联到实例。" \
  || log "Lex 机器人已关联或跳过关联（继续）。" >&2

# Resolve the target queue ARN (fall back to the first standard queue).
TARGET_QUEUE_ARN="$(aws connect list-queues \
  --instance-id "$TARGET_INSTANCE_ID" --queue-types STANDARD \
  --region "$TARGET_REGION" \
  --query "QueueSummaryList[?Name=='${TARGET_QUEUE_NAME}'].Arn | [0]" \
  --output text 2>/dev/null || true)"
if [ -z "$TARGET_QUEUE_ARN" ] || [ "$TARGET_QUEUE_ARN" = "None" ]; then
  TARGET_QUEUE_ARN="$(aws connect list-queues \
    --instance-id "$TARGET_INSTANCE_ID" --queue-types STANDARD \
    --region "$TARGET_REGION" \
    --query "QueueSummaryList[0].Arn" --output text 2>/dev/null || true)"
fi
[ -n "$TARGET_QUEUE_ARN" ] && [ "$TARGET_QUEUE_ARN" != "None" ] \
  || warn "未找到标准队列，flow 的转接步骤可能无效。"
ok "目标队列              : $TARGET_QUEUE_ARN"

# New target ARNs for the AI agents at $LATEST.
NEW_CHAT_AGENT_ARN="arn:${QIC_PARTITION}:${QIC_SERVICE}:${QIC_ARN_REGION}:${QIC_ACCOUNT}:ai-agent/${ASSISTANT_ID}/${CHAT_AGENT_ID}:\$LATEST"
NEW_VOICE_AGENT_ARN="arn:${QIC_PARTITION}:${QIC_SERVICE}:${QIC_ARN_REGION}:${QIC_ACCOUNT}:ai-agent/${ASSISTANT_ID}/${VOICE_AGENT_ID}:\$LATEST"

# Best-effort: resolve the new Lex bot's display name for the console dropdown.
LEX_BOT_ID="$(printf '%s' "$LEX_ALIAS_ARN" | sed -n 's#.*:bot-alias/\([^/]*\)/.*#\1#p')"
NEW_LEX_BOT_NAME="$(aws lexv2-models describe-bot --bot-id "$LEX_BOT_ID" \
  --region "$TARGET_REGION" --query 'botName' --output text 2>/dev/null || true)"
[ -n "$NEW_LEX_BOT_NAME" ] && [ "$NEW_LEX_BOT_NAME" != "None" ] || NEW_LEX_BOT_NAME="$FLOW_OLD_LEX_BOT_NAME"

# Grant the Lex bot's runtime role access to the target Q in Connect assistant so
# its QnAIntent can reach the AI agents we created. Service-linked roles cannot
# take inline policies, in which case the assistant must be set on the bot's
# Amazon Q in Connect intent in the Lex console instead.
LEX_BOT_ROLE_ARN="$(aws lexv2-models describe-bot --bot-id "$LEX_BOT_ID" \
  --region "$TARGET_REGION" --query 'roleArn' --output text 2>/dev/null || true)"
if [ -z "$LEX_BOT_ROLE_ARN" ] || [ "$LEX_BOT_ROLE_ARN" = "None" ]; then
  warn "无法获取 Lex 机器人运行时角色，跳过 assistant 访问授权。"
else
  LEX_BOT_ROLE_NAME="${LEX_BOT_ROLE_ARN##*/}"
  case "$LEX_BOT_ROLE_ARN" in
    *:role/aws-service-role/*)
      warn "Lex 机器人使用服务相关角色（service-linked role）'$LEX_BOT_ROLE_NAME'，无法附加策略。请在 Lex 控制台把该机器人的 Amazon Q in Connect intent 的 assistant 设为 ${TARGET_ASSISTANT_ARN}，然后构建并发布 TestBotAlias。" ;;
    *)
      LEX_GRANT_POLICY="$(jq -n \
        --arg assistant "$TARGET_ASSISTANT_ARN" \
        --arg agents "arn:${QIC_PARTITION}:${QIC_SERVICE}:${QIC_ARN_REGION}:${QIC_ACCOUNT}:ai-agent/${ASSISTANT_ID}/*" \
        --arg sessions "arn:${QIC_PARTITION}:${QIC_SERVICE}:${QIC_ARN_REGION}:${QIC_ACCOUNT}:session/${ASSISTANT_ID}/*" '
        {Version:"2012-10-17",Statement:[{Effect:"Allow",Action:["wisdom:*"],Resource:[$assistant,$agents,$sessions]}]}')"
      aws iam put-role-policy \
        --role-name "$LEX_BOT_ROLE_NAME" \
        --policy-name "QInConnect-${ASSISTANT_ID}" \
        --policy-document "$LEX_GRANT_POLICY" >/dev/null 2>&1 \
        && ok "已为 Lex 机器人角色 '$LEX_BOT_ROLE_NAME' 授予对 assistant $ASSISTANT_ID 的访问权限。" \
        || warn "无法为 Lex 机器人角色 '$LEX_BOT_ROLE_NAME' 附加访问策略（请检查 IAM 权限）。" ;;
  esac
fi

# Rewrite every target-specific literal in the flow (exact string matches).
FLOW_CONTENT_FILE="$(mktemp)"
trap 'rm -f "$FLOW_CONTENT_FILE"' EXIT
jq \
  --arg aOld "$FLOW_OLD_ASSISTANT_ARN"    --arg aNew "$TARGET_ASSISTANT_ARN" \
  --arg cOld "$FLOW_OLD_CHAT_AGENT_ARN"   --arg cNew "$NEW_CHAT_AGENT_ARN" \
  --arg vOld "$FLOW_OLD_VOICE_AGENT_ARN"  --arg vNew "$NEW_VOICE_AGENT_ARN" \
  --arg lOld "$FLOW_OLD_LAMBDA_ARN"       --arg lNew "$LAMBDA_ARN" \
  --arg xOld "$FLOW_OLD_LEX_ALIAS_ARN"    --arg xNew "$LEX_ALIAS_ARN" \
  --arg qOld "$FLOW_OLD_QUEUE_ARN"        --arg qNew "$TARGET_QUEUE_ARN" \
  --arg cnOld "$FLOW_OLD_CHAT_AGENT_NAME"  --arg cnNew "$CHAT_AGENT_NAME" \
  --arg vnOld "$FLOW_OLD_VOICE_AGENT_NAME" --arg vnNew "$VOICE_AGENT_NAME" \
  --arg bnOld "$FLOW_OLD_LEX_BOT_NAME"     --arg bnNew "$NEW_LEX_BOT_NAME" \
  --arg fnOld "$FLOW_OLD_NAME"             --arg fnNew "$FLOW_NAME" \
  --arg phOld "$FLOW_OLD_PHONE"            --arg phNew "$FLOW_NEW_PHONE" \
  --arg buOld "$FLOW_OLD_BU"               --arg buNew "$FLOW_NEW_BU" \
  'walk(
     if type=="string" then
       if   . == $aOld  then $aNew
       elif . == $cOld  then $cNew
       elif . == $vOld  then $vNew
       elif . == $lOld  then $lNew
       elif . == $xOld  then $xNew
       elif . == $qOld  then $qNew
       elif . == $cnOld then $cnNew
       elif . == $vnOld then $vnNew
       elif . == $bnOld then $bnNew
       elif . == $fnOld then $fnNew
       elif . == $phOld then $phNew
       elif . == $buOld then $buNew
       else . end
     else . end
   )' "$FLOW_JSON_FILE" > "$FLOW_CONTENT_FILE" || die "改写 flow JSON 失败。"

EXISTING_FLOW_ID="$(aws connect list-contact-flows \
  --instance-id "$TARGET_INSTANCE_ID" --region "$TARGET_REGION" \
  --query "ContactFlowSummaryList[?Name=='${FLOW_NAME}'].Id | [0]" \
  --output text 2>/dev/null || true)"

if [ -n "$EXISTING_FLOW_ID" ] && [ "$EXISTING_FLOW_ID" != "None" ]; then
  aws connect update-contact-flow-content \
    --instance-id "$TARGET_INSTANCE_ID" \
    --contact-flow-id "$EXISTING_FLOW_ID" \
    --content "file://$FLOW_CONTENT_FILE" \
    --region "$TARGET_REGION" >/dev/null || die "update-contact-flow-content 失败。"
  FLOW_ID="$EXISTING_FLOW_ID"
  ok "已更新现有 contact flow -> $FLOW_ID"
else
  FLOW_ID="$(aws connect create-contact-flow \
    --instance-id "$TARGET_INSTANCE_ID" \
    --name "$FLOW_NAME" \
    --type "$FLOW_TYPE" \
    --content "file://$FLOW_CONTENT_FILE" \
    --region "$TARGET_REGION" \
    --query 'ContactFlowId' --output text)" || die "create-contact-flow 失败。"
  ok "已创建 contact flow -> $FLOW_ID"
fi

# ============================================================================
# 7. Reconfigure the Lex bot's Q in Connect intent to the target assistant
# ============================================================================
# TestBotAlias (TSTALIASID) always serves the bot's DRAFT version, so updating
# the intent on DRAFT + building the locale is sufficient (no version/alias work).
# Set RECONFIGURE_LEX_BOT=false to skip.
if [ "${RECONFIGURE_LEX_BOT:-true}" = "true" ]; then
  log "=== 重新配置 Lex 机器人的 Q in Connect intent -> $TARGET_ASSISTANT_ARN ==="
  INTENT_TMP="$(mktemp)"
  trap 'rm -f "$FLOW_CONTENT_FILE" "$INTENT_TMP"' EXIT

  LEX_RECONFIGURED=false
  LEX_LOCALES="$(aws lexv2-models list-bot-locales \
    --bot-id "$LEX_BOT_ID" --bot-version DRAFT --region "$TARGET_REGION" \
    --query 'botLocaleSummaries[].localeId' --output text 2>/dev/null || true)"
  [ -n "$LEX_LOCALES" ] || warn "机器人 $LEX_BOT_ID 上未找到 DRAFT 语言区域。"

  for loc in $LEX_LOCALES; do
    built_needed=false
    intent_ids="$(aws lexv2-models list-intents \
      --bot-id "$LEX_BOT_ID" --bot-version DRAFT --locale-id "$loc" \
      --region "$TARGET_REGION" \
      --query 'intentSummaries[].intentId' --output text 2>/dev/null || true)"
    for iid in $intent_ids; do
      desc="$(aws lexv2-models describe-intent \
        --bot-id "$LEX_BOT_ID" --bot-version DRAFT --locale-id "$loc" --intent-id "$iid" \
        --region "$TARGET_REGION" --output json 2>/dev/null || true)"
      [ -n "$desc" ] || continue
      cur="$(printf '%s' "$desc" | jq -r '.qInConnectIntentConfiguration.qInConnectAssistantConfiguration.assistantArn // empty')"
      [ -n "$cur" ] || continue   # not a Q in Connect intent

      printf '%s' "$desc" \
        | jq --arg a "$TARGET_ASSISTANT_ARN" \
            'del(.creationDateTime, .lastUpdatedDateTime)
             | .qInConnectIntentConfiguration.qInConnectAssistantConfiguration.assistantArn = $a' \
        > "$INTENT_TMP"
      if aws lexv2-models update-intent --cli-input-json "file://$INTENT_TMP" \
          --region "$TARGET_REGION" >/dev/null 2>&1; then
        ok "已将 Q in Connect intent '$(printf '%s' "$desc" | jq -r .intentName)'（${loc}）指向目标 assistant。"
        built_needed=true; LEX_RECONFIGURED=true
      else
        warn "intent ${iid}（${loc}）的 update-intent 失败。"
      fi
    done
    if [ "$built_needed" = "true" ]; then
      log "正在构建语言区域 $loc ..." >&2
      if aws lexv2-models build-bot-locale \
          --bot-id "$LEX_BOT_ID" --bot-version DRAFT --locale-id "$loc" \
          --region "$TARGET_REGION" >/dev/null 2>&1; then
        aws lexv2-models wait bot-locale-built \
          --bot-id "$LEX_BOT_ID" --bot-version DRAFT --locale-id "$loc" \
          --region "$TARGET_REGION" 2>/dev/null || true
        ok "已构建语言区域 ${loc}（TestBotAlias 现在使用新的 assistant）。"
      else
        warn "$loc 的 build-bot-locale 失败。"
      fi
    fi
  done

  [ "$LEX_RECONFIGURED" = "true" ] \
    || warn "机器人 $LEX_BOT_ID 上未找到 Q in Connect intent；请手动在该机器人的 Amazon Q in Connect intent 上设置 assistant。"
else
  log "RECONFIGURE_LEX_BOT=false，跳过 Lex 机器人 intent 重新配置。" >&2
fi

# ============================================================================
# Summary
# ============================================================================
echo
ok "所有资源已成功创建："
printf '  %-38s %s\n' "$VOICE_PROMPT_NAME" "$VOICE_PROMPT_ID"
printf '  %-38s %s\n' "$CHAT_PROMPT_NAME"  "$CHAT_PROMPT_ID"
printf '  %-38s %s\n' "$VOICE_AGENT_NAME"  "$VOICE_AGENT_ID"
printf '  %-38s %s\n' "$CHAT_AGENT_NAME"   "$CHAT_AGENT_ID"
printf '  %-38s %s\n' "$SECURITY_PROFILE_NAME" "$SECURITY_PROFILE_ID"
printf '  %-38s %s\n' "$LAMBDA_FUNCTION_NAME" "$LAMBDA_ARN"
printf '  %-38s %s\n' "$FLOW_NAME" "$FLOW_ID"
echo
ok "安全配置文件 '$SECURITY_PROFILE_NAME' 已关联到两个 AI agent。"
ok "contact flow 已导入：CHAT->${CHAT_AGENT_NAME}，VOICE->${VOICE_AGENT_NAME}（版本 \$LATEST）。"
