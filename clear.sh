#!/usr/bin/env bash
#
# clear.sh
#
# Tears down every resource recorded in a manifest produced by
# create_connect_ai_agents.sh. The manifest is a JSON-lines file (one JSON
# object per line); this script reads it and deletes the resources it lists in a
# dependency-safe order:
#
#   1. Contact flows            (reference AI agents / Lambdas)
#   2. AI agents                (+ their versions)
#   3. AI prompts               (+ their versions)
#   4. Security profiles
#   5. Lambda functions         (disassociate from instance, then delete)
#   6. Lex bot associations     (disassociate from instance)
#   7. IAM inline role policies  (only those added to pre-existing roles)
#   8. IAM roles                (detach managed + delete inline, then delete role)
#   9. Knowledge bases          (delete integration association, then the KB)
#  10. Assistants               (delete integration association, then the assistant)
#
# Only resources the create script actually CREATED are recorded, so reused /
# pre-existing resources are never touched.
#
# Requirements: awscli v2, jq.
#
# Usage:
#   ./clear.sh <manifest-file>         # prompts before deleting
#   ./clear.sh -y <manifest-file>      # no confirmation (also: FORCE=true)
#
set -uo pipefail

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
log()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m  %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[FAIL]\033[0m  %s\n' "$*" >&2; exit 1; }

command -v aws >/dev/null 2>&1 || die "未找到 aws CLI，请安装 AWS CLI v2。"
command -v jq  >/dev/null 2>&1 || die "未找到 jq，请安装 jq（例如 'brew install jq'）。"

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
FORCE="${FORCE:-false}"
MANIFEST=""
for arg in "$@"; do
  case "$arg" in
    -y|--yes) FORCE=true ;;
    -*)       die "未知选项：$arg" ;;
    *)        MANIFEST="$arg" ;;
  esac
done

if [ -z "$MANIFEST" ]; then
  printf '请输入要删除的资源清单文件路径: '
  read -r MANIFEST
fi
[ -n "$MANIFEST" ] || die "未提供资源清单文件。"
[ -f "$MANIFEST" ] || die "找不到资源清单文件：$MANIFEST"

# Validate that every line is valid JSON before touching anything.
if ! jq -e . "$MANIFEST" >/dev/null 2>&1; then
  die "资源清单文件不是有效的 JSON-lines 格式：$MANIFEST"
fi

# records_of <type> : print every manifest line whose .type matches.
records_of() { jq -c --arg t "$1" 'select(.type==$t)' "$MANIFEST"; }

# field <json> <key> : print a single field (empty if absent/null).
field() { jq -r --arg k "$2" '.[$k] // empty' <<<"$1"; }

# ----------------------------------------------------------------------------
# Show a summary and confirm before deleting.
# ----------------------------------------------------------------------------
META="$(records_of meta | head -n1)"
if [ -n "$META" ]; then
  log "清单实例  : $(field "$META" instanceArn)"
  log "清单区域  : $(field "$META" region)"
  log "创建时间  : $(field "$META" createdAt)"
  [ -n "$(field "$META" suffix)" ] && log "名称后缀  : $(field "$META" suffix)"
fi

log "即将删除以下资源："
jq -r 'select(.type!="meta")
       | "  - \(.type): \(.name // .functionName // .roleName // .contactFlowId // .aiAgentId // .aiPromptId // .knowledgeBaseId // .assistantId // .policyName // .aliasArn // "?")"' \
  "$MANIFEST" || true

if [ "$FORCE" != "true" ]; then
  printf '\n确认删除以上所有资源？此操作不可撤销。输入 "yes" 继续: '
  read -r reply
  [ "$reply" = "yes" ] || die "已取消。"
fi

# ============================================================================
# 1. Contact flows
# ============================================================================
while IFS= read -r rec; do
  [ -n "$rec" ] || continue
  region="$(field "$rec" region)"; instance="$(field "$rec" instanceId)"
  flow="$(field "$rec" contactFlowId)"; name="$(field "$rec" name)"
  log "删除 contact flow '$name' ($flow) ..."
  aws connect delete-contact-flow \
    --instance-id "$instance" --contact-flow-id "$flow" \
    --region "$region" >/dev/null 2>&1 \
    && ok "已删除 contact flow '$name'。" \
    || warn "无法删除 contact flow '$name' ($flow)（可能已删除）。"
done < <(records_of CONTACT_FLOW)

# ============================================================================
# 2. AI agents (delete versions first, then the agent)
# ============================================================================
while IFS= read -r rec; do
  [ -n "$rec" ] || continue
  region="$(field "$rec" region)"; assistant="$(field "$rec" assistantArn)"
  agent="$(field "$rec" aiAgentId)"; name="$(field "$rec" name)"
  log "删除 AI agent '$name' ($agent) ..."
  # Best-effort: remove published versions so the agent can be deleted.
  for ver in $(aws qconnect list-ai-agent-versions \
      --assistant-id "$assistant" --ai-agent-id "$agent" \
      --region "$region" --output json 2>/dev/null \
      | jq -r '.aiAgentVersionSummaries[]?.versionNumber // empty'); do
    aws qconnect delete-ai-agent-version \
      --assistant-id "$assistant" --ai-agent-id "$agent" --version-number "$ver" \
      --region "$region" >/dev/null 2>&1 || true
  done
  aws qconnect delete-ai-agent \
    --assistant-id "$assistant" --ai-agent-id "$agent" \
    --region "$region" >/dev/null 2>&1 \
    && ok "已删除 AI agent '$name'。" \
    || warn "无法删除 AI agent '$name' ($agent)（可能已删除）。"
done < <(records_of AI_AGENT)

# ============================================================================
# 3. AI prompts (delete versions first, then the prompt)
# ============================================================================
while IFS= read -r rec; do
  [ -n "$rec" ] || continue
  region="$(field "$rec" region)"; assistant="$(field "$rec" assistantArn)"
  prompt="$(field "$rec" aiPromptId)"; name="$(field "$rec" name)"
  log "删除 AI prompt '$name' ($prompt) ..."
  for ver in $(aws qconnect list-ai-prompt-versions \
      --assistant-id "$assistant" --ai-prompt-id "$prompt" \
      --region "$region" --output json 2>/dev/null \
      | jq -r '.aiPromptVersionSummaries[]?.versionNumber // empty'); do
    aws qconnect delete-ai-prompt-version \
      --assistant-id "$assistant" --ai-prompt-id "$prompt" --version-number "$ver" \
      --region "$region" >/dev/null 2>&1 || true
  done
  aws qconnect delete-ai-prompt \
    --assistant-id "$assistant" --ai-prompt-id "$prompt" \
    --region "$region" >/dev/null 2>&1 \
    && ok "已删除 AI prompt '$name'。" \
    || warn "无法删除 AI prompt '$name' ($prompt)（可能已删除）。"
done < <(records_of AI_PROMPT)

# ============================================================================
# 4. Security profiles
# ============================================================================
while IFS= read -r rec; do
  [ -n "$rec" ] || continue
  region="$(field "$rec" region)"; instance="$(field "$rec" instanceId)"
  sp="$(field "$rec" securityProfileId)"; name="$(field "$rec" name)"
  log "删除安全配置文件 '$name' ($sp) ..."
  aws connect delete-security-profile \
    --instance-id "$instance" --security-profile-id "$sp" \
    --region "$region" >/dev/null 2>&1 \
    && ok "已删除安全配置文件 '$name'。" \
    || warn "无法删除安全配置文件 '$name' ($sp)（可能已删除或仍被引用）。"
done < <(records_of SECURITY_PROFILE)

# ============================================================================
# 5. Lambda functions (disassociate from instance, then delete)
# ============================================================================
while IFS= read -r rec; do
  [ -n "$rec" ] || continue
  region="$(field "$rec" region)"; instance="$(field "$rec" instanceId)"
  fn="$(field "$rec" functionName)"
  log "删除 Lambda '$fn' ..."
  arn="$(aws lambda get-function --function-name "$fn" --region "$region" \
    --query 'Configuration.FunctionArn' --output text 2>/dev/null || true)"
  if [ -n "$arn" ] && [ "$arn" != "None" ]; then
    aws connect disassociate-lambda-function \
      --instance-id "$instance" --function-arn "$arn" \
      --region "$region" >/dev/null 2>&1 \
      && log "已将 Lambda '$fn' 从实例解除关联。" \
      || log "Lambda '$fn' 未关联到实例（继续）。"
  fi
  aws lambda delete-function --function-name "$fn" --region "$region" >/dev/null 2>&1 \
    && ok "已删除 Lambda '$fn'。" \
    || warn "无法删除 Lambda '$fn'（可能已删除）。"
done < <(records_of LAMBDA_FUNCTION)

# ============================================================================
# 6. Lex bot associations (disassociate from instance)
# ============================================================================
while IFS= read -r rec; do
  [ -n "$rec" ] || continue
  region="$(field "$rec" region)"; instance="$(field "$rec" instanceId)"
  alias_arn="$(field "$rec" aliasArn)"
  log "解除 Lex 机器人关联 ($alias_arn) ..."
  aws connect disassociate-bot \
    --instance-id "$instance" --lex-v2-bot "AliasArn=$alias_arn" \
    --region "$region" >/dev/null 2>&1 \
    && ok "已解除 Lex 机器人关联。" \
    || warn "无法解除 Lex 机器人关联（可能已解除）。"
done < <(records_of LEX_BOT_ASSOCIATION)

# ============================================================================
# 7. IAM inline role policies (added to pre-existing roles)
# ============================================================================
while IFS= read -r rec; do
  [ -n "$rec" ] || continue
  role="$(field "$rec" roleName)"; policy="$(field "$rec" policyName)"
  log "删除内联策略 '$policy'（角色 '$role'）..."
  aws iam delete-role-policy --role-name "$role" --policy-name "$policy" >/dev/null 2>&1 \
    && ok "已删除内联策略 '$policy'。" \
    || warn "无法删除内联策略 '$policy'（角色可能已删除）。"
done < <(records_of IAM_ROLE_POLICY)

# ============================================================================
# 8. IAM roles (detach managed policies + delete inline policies, then role)
# ============================================================================
while IFS= read -r rec; do
  [ -n "$rec" ] || continue
  role="$(field "$rec" roleName)"
  log "删除 IAM 角色 '$role' ..."
  for parn in $(aws iam list-attached-role-policies --role-name "$role" \
      --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true); do
    [ -n "$parn" ] && [ "$parn" != "None" ] || continue
    aws iam detach-role-policy --role-name "$role" --policy-arn "$parn" >/dev/null 2>&1 || true
  done
  for pol in $(aws iam list-role-policies --role-name "$role" \
      --query 'PolicyNames[]' --output text 2>/dev/null || true); do
    [ -n "$pol" ] && [ "$pol" != "None" ] || continue
    aws iam delete-role-policy --role-name "$role" --policy-name "$pol" >/dev/null 2>&1 || true
  done
  aws iam delete-role --role-name "$role" >/dev/null 2>&1 \
    && ok "已删除 IAM 角色 '$role'。" \
    || warn "无法删除 IAM 角色 '$role'（可能已删除或仍被引用）。"
done < <(records_of IAM_ROLE)

# ============================================================================
# 9. Knowledge bases (delete integration association, then the KB)
# ============================================================================
while IFS= read -r rec; do
  [ -n "$rec" ] || continue
  region="$(field "$rec" region)"; instance="$(field "$rec" instanceId)"
  kb_id="$(field "$rec" knowledgeBaseId)"; kb_arn="$(field "$rec" knowledgeBaseArn)"
  name="$(field "$rec" name)"
  log "删除知识库 '$name' ($kb_id) ..."
  assoc_id="$(aws connect list-integration-associations \
    --instance-id "$instance" --integration-type WISDOM_KNOWLEDGE_BASE \
    --region "$region" --output json 2>/dev/null \
    | jq -r --arg a "$kb_arn" \
        '.IntegrationAssociationSummaryList[]? | select(.IntegrationArn==$a) | .IntegrationAssociationId' \
    | head -n1)"
  if [ -n "$assoc_id" ]; then
    aws connect delete-integration-association \
      --instance-id "$instance" --integration-association-id "$assoc_id" \
      --region "$region" >/dev/null 2>&1 \
      && log "已删除知识库与实例的集成关联。" \
      || warn "无法删除知识库集成关联（继续）。"
  fi
  aws qconnect delete-knowledge-base \
    --knowledge-base-id "$kb_id" --region "$region" >/dev/null 2>&1 \
    && ok "已删除知识库 '$name'。" \
    || warn "无法删除知识库 '$name' ($kb_id)（可能已删除）。"
done < <(records_of KNOWLEDGE_BASE)

# ============================================================================
# 10. Assistants (delete integration association, then the assistant)
# ============================================================================
while IFS= read -r rec; do
  [ -n "$rec" ] || continue
  region="$(field "$rec" region)"; instance="$(field "$rec" instanceId)"
  as_id="$(field "$rec" assistantId)"; as_arn="$(field "$rec" assistantArn)"
  name="$(field "$rec" name)"
  log "删除 assistant '$name' ($as_id) ..."
  assoc_id="$(aws connect list-integration-associations \
    --instance-id "$instance" --integration-type WISDOM_ASSISTANT \
    --region "$region" --output json 2>/dev/null \
    | jq -r --arg a "$as_arn" \
        '.IntegrationAssociationSummaryList[]? | select(.IntegrationArn==$a) | .IntegrationAssociationId' \
    | head -n1)"
  if [ -n "$assoc_id" ]; then
    aws connect delete-integration-association \
      --instance-id "$instance" --integration-association-id "$assoc_id" \
      --region "$region" >/dev/null 2>&1 \
      && log "已删除 assistant 与实例的集成关联。" \
      || warn "无法删除 assistant 集成关联（继续）。"
  fi
  aws qconnect delete-assistant \
    --assistant-id "$as_id" --region "$region" >/dev/null 2>&1 \
    && ok "已删除 assistant '$name'。" \
    || warn "无法删除 assistant '$name' ($as_id)（可能已删除）。"
done < <(records_of ASSISTANT)

echo
ok "清理完成。已按资源清单 '$MANIFEST' 处理所有条目。"
log "提示：若某些资源因依赖关系删除失败，可重新运行本脚本重试。"
