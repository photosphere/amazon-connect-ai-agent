# Amazon Connect AI Agent 一键部署脚本

`create_connect_ai_agents.sh` 用于在指定的 **Amazon Connect 实例** 上，一键创建并配置 Amazon Q in Connect 的自助式（Self-Service）AI Agent，并导入配套的联系流程（contact flow）。

脚本会在目标实例的 Q in Connect domain（assistant）中创建 prompt / agent，并完成 Lambda 部署、安全配置文件关联、流程导入以及 Lex 机器人对接。

---

## 一、脚本会创建/配置的资源

| 类型 | 名称 | 说明 |
|------|------|------|
| AI Prompt | `SelfServiceOrchestrationVoice_Prompt` | 创建并发布版本 |
| AI Prompt | `SelfServiceOrchestrationChat_Prompt` | 创建并发布版本 |
| AI Agent | `SelfServiceOrchestrator_Voice_Agent` | ORCHESTRATION 类型，工具仅保留 `Complete`、`Escalate` |
| AI Agent | `SelfServiceOrchestrator_Chat_Agent` | ORCHESTRATION 类型，工具仅保留 `Complete`、`Escalate` |
| Security Profile | `AI-Agent` | 创建后关联到上述两个 AI Agent |
| Lambda | `ConnectAssistantUpdateSessionData` | 部署 zip、设置环境变量、授予运行时权限、关联到实例 |
| Contact Flow | `AI Agent - MCP Inbound Flow` | 从 JSON 模板导入，并重写为目标资源 |

执行流程（共 7 步）：

1. **AI Prompts**：在目标 assistant 中创建并发布版本（已存在则复用）。
2. **AI Agents**：创建 AI Agent，工具裁剪为 `Complete` + `Escalate`，并指向上一步的 prompt（已存在则复用）。
3. **Security Profile**：创建 `AI-Agent`（已存在则复用）。
4. **关联安全配置文件**：通过 SigV4 直接调用 `AssociateSecurityProfiles`，把 `AI-Agent` 绑定到两个 agent 的 `$SAVED` 版本。
5. **部署 Lambda**：部署/更新 `ConnectAssistantUpdateSessionData`，设置 `AI_ASSISTANT_ID`、`CONNECT_INSTANCE_ID` 环境变量，授予 `connect:DescribeContact` + `UpdateSessionData`，并关联到实例。
6. **导入 Contact Flow**：把模板 JSON 中的 assistant / agent / Lambda / Lex 别名 / 队列等替换为目标值后导入（同名则更新）。CHAT 用 Chat agent、VOICE 用 Voice agent，版本均为 `$LATEST`。
7. **重配 Lex 机器人**：把 Lex 机器人的 Amazon Q in Connect intent 指向目标 assistant，并重建 locale（`TestBotAlias` 始终指向 DRAFT 版本）。

---

## 二、前置条件

- **AWS CLI v2**、**jq**、**curl**（需支持 `--aws-sigv4`，即 curl ≥ 7.75；macOS 自带的 curl 通常已支持）。
- 已配置好可用的 AWS 凭证（`aws configure` / 环境变量 / SSO / 角色均可）。
- 同目录下需存在两个文件（也可用环境变量改路径）：
  - `AI Agent - MCP Inbound Flow.json`（联系流程模板）
  - `ConnectAssistantUpdateSessionData-dbcd9ed4-0218-4522-adff-b9850c8b80eb.zip`（Lambda 代码）
- 运行凭证需要的权限（概要）：
  - `qconnect:*`（创建/读取 prompt、agent、assistant、knowledge-base 等）
  - `connect:*`（list/create-integration-association、create-security-profile、associate-security-profiles、associate-lambda-function、associate-bot、create/update-contact-flow、list-queues 等）
  - `lambda:*`（create/update-function、add-permission 等）
  - `iam:CreateRole/PutRolePolicy/AttachRolePolicy/GetRole`（自动创建 Lambda 执行角色、给 Lambda/Lex 角色加策略时）
  - `lex:ListBotLocales/ListIntents/DescribeIntent/UpdateIntent/BuildBotLocale/DescribeBot`

---

## 三、用法

```bash
chmod +x create_connect_ai_agents.sh
./create_connect_ai_agents.sh [目标Connect实例ARN] [目标AssistantARN(可选)]
```

- **不带参数**运行时，脚本会交互式提示：
  1. 输入目标 Amazon Connect 实例 ARN；
  2. 输入 Lex 机器人 ARN（脚本固定使用 `TestBotAlias`，即别名 ID `TSTALIASID`）。
- **第二个参数**可显式指定目标 Q in Connect assistant ARN；不传时脚本会：
  - 先查找实例已关联的 assistant；
  - 找不到则提示输入一个 **domain（assistant）名称**：
    - 若该名称已存在 → 复用并关联到实例；
    - 否则新建 assistant（默认同时创建并关联一个知识库）；
    - **禁止**使用名称 `SelfServiceOrchestrator_Voice-Assistant`。

示例：

```bash
# 交互式
./create_connect_ai_agents.sh

# 直接给实例 ARN，Lex ARN 用环境变量
LEX_BOT_ARN=arn:aws:lex:us-west-2:111122223333:bot/ABCDEF1234 \
  ./create_connect_ai_agents.sh arn:aws:connect:us-west-2:111122223333:instance/xxxx

# 显式指定目标 assistant
./create_connect_ai_agents.sh \
  arn:aws:connect:us-west-2:111122223333:instance/xxxx \
  arn:aws:wisdom:us-west-2:111122223333:assistant/db039297-...
```

---

## 四、可用环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `LEX_BOT_ARN` | （交互输入） | Lex 机器人 ARN（bot 或 bot-alias 均可，始终用 TestBotAlias） |
| `NEW_ASSISTANT_NAME` | （需要时交互输入） | 新建/复用 domain 的名称；不可为禁用名 |
| `NEW_KNOWLEDGE_BASE_NAME` | `<domain名>-KnowledgeBase` | 新建知识库名称 |
| `CREATE_KNOWLEDGE_BASE` | `true` | 设为 `false` 则只建/关联 assistant，不建知识库 |
| `REF_ASSISTANT_ARN` | 内置 | 模板 assistant ARN |
| `REF_VOICE_PROMPT_ID` / `REF_CHAT_PROMPT_ID` | 内置 | 模板 prompt ID |
| `REF_VOICE_AGENT_ID` / `REF_CHAT_AGENT_ID` | 内置 | 模板 agent ID |
| `FLOW_JSON_FILE` | `AI Agent - MCP Inbound Flow.json` | 联系流程模板路径 |
| `FLOW_NAME` | `AI Agent - MCP Inbound Flow` | 导入后的流程名称 |
| `FLOW_NEW_PHONE` | `12345678900` | 流程中 Lambda 入参 phoneNumber 的替换值 |
| `FLOW_NEW_BU` | `US` | 流程中 Lambda 入参 BU 的替换值 |
| `LAMBDA_ZIP_FILE` | `ConnectAssistantUpdateSessionData-...zip` | Lambda 代码 zip 路径 |
| `LAMBDA_FUNCTION_NAME` | `ConnectAssistantUpdateSessionData` | Lambda 函数名 |
| `LAMBDA_RUNTIME` | `nodejs20.x` | Lambda 运行时 |
| `LAMBDA_HANDLER` | `index.handler` | Lambda 入口 |
| `LAMBDA_ROLE_ARN` | （空，自动创建） | 指定后使用现有执行角色，不自动创建 IAM 角色 |
| `TARGET_QUEUE_NAME` | `BasicQueue` | 流程转接绑定的队列名（找不到则取第一个标准队列） |
| `TARGET_GUARDRAIL_ID` | （空，移除） | 指定后给 agent 设置该 AI Guardrail，否则不设置 guardrail |
| `AGENT_ENTITY_QUALIFIER` | `$SAVED` | 关联安全配置文件时使用的 agent 版本限定符 |
| `RECONFIGURE_LEX_BOT` | `true` | 设为 `false` 跳过第 7 步（不改 Lex 机器人 intent） |

---

## 五、幂等性与重复执行

脚本可重复运行：同名的 prompt / agent / 安全配置文件 / 流程 / 已发布版本会被**复用或更新**，不会重复创建报错。

---

## 六、注意事项

- **建议显式指定目标 assistant**：不传第二个参数时，脚本会使用实例当前关联的 assistant；如需确保资源落到指定 domain，建议用第二个参数显式指定目标 assistant ARN。
- **Lambda 代码依赖**：zip 内 `index.js` 使用 `@aws-sdk/client-qconnect`、`@aws-sdk/client-connect`。Node.js 20 运行时已内置 AWS SDK v3，通常可用；若运行时报“找不到模块”，需重新打包并附带依赖。
- **IAM 写操作**：未提供 `LAMBDA_ROLE_ARN` 时脚本会自动创建/修改 IAM 角色与策略；如不希望脚本动 IAM，请预先创建角色并通过 `LAMBDA_ROLE_ARN` 传入。
- **Lex 机器人**：若机器人使用服务相关角色（service-linked role），脚本无法为其附加策略，会提示你在 Lex 控制台手动把 Q in Connect intent 的 assistant 设为目标 assistant 后构建并发布 `TestBotAlias`。

---

## 七、相关文件

| 文件 | 用途 |
|------|------|
| `create_connect_ai_agents.sh` | 主脚本 |
| `AI Agent - MCP Inbound Flow.json` | 联系流程模板（导入时按目标资源重写） |
| `ConnectAssistantUpdateSessionData-...zip` | Lambda 函数代码 |
