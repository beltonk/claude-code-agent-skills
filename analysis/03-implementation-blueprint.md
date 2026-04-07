# Claude Code Implementation Blueprint

> This document provides a detailed implementation blueprint for Claude Code's agentic harness, with enough detail to design and build a comparable system.

---

## 1. System Component Map

The following graph shows the full component dependency tree from entrypoints through the query engine to supporting services. Every node is a real module or module group in `src/`.

```
Entrypoints
├─ cli.tsx          Bootstrap; fast-path --version, dynamic import to main.tsx
├─ main.tsx         Commander CLI parsing, option mutation, config hydration, launchRepl()
├─ replLauncher.tsx Ink/React terminal bootstrap
├─ init.ts          Memoized one-time initialization (analytics, GrowthBook, trust, telemetry)
└─ entrypoints/     mcp.ts (MCP server mode), sdk/ (programmatic SDK entrypoint)

REPL / App (React + Ink terminal UI)
├─ components/      389 modules — messages, permissions dialogs, prompt input, agent panels
├─ ink/             96 modules — custom renderer, yoga layout, events, search, screen
└─ hooks/           104 modules — notifications, IDE connection, permissions, voice, plugins

QueryEngine (src/QueryEngine.ts — conversation lifecycle)
├─ query() / queryLoop()                 Agentic while-true loop (src/query.ts)
│    ├─ Context Preparation Pipeline
│    │    ├─ getMessagesAfterCompactBoundary()   Strip pre-compact history
│    │    ├─ applyToolResultBudget()              Per-message size enforcement
│    │    ├─ snipCompactIfNeeded()                [HISTORY_SNIP] token-reclaiming snip
│    │    ├─ microcompact()                       Short-lived compaction / cache editing
│    │    ├─ applyCollapsesIfNeeded()             [CONTEXT_COLLAPSE] staged context folding
│    │    └─ autocompactIfNeeded()                Proactive full compaction via forked agent
│    ├─ Model Streaming
│    │    ├─ callModel()                          API call with streaming response
│    │    ├─ FallbackTriggeredError               Model switch + retry on overload
│    │    └─ StreamingToolExecutor                 Concurrent tool start during stream
│    ├─ Post-Streaming Recovery Cascade
│    │    ├─ Prompt-too-long → collapseDrain → reactiveCompact → fail
│    │    ├─ Max output tokens → escalate 64K → multi-turn recovery (3×) → fail
│    │    └─ Media size errors → reactiveCompact strip-retry
│    ├─ Stop Hooks
│    │    ├─ handleStopHooks()                    Post-turn validation hooks
│    │    ├─ preventContinuation                  Hook can terminate query
│    │    └─ blockingErrors                       Hook can inject errors → retry
│    ├─ Token Budget (TOKEN_BUDGET feature)
│    │    ├─ checkTokenBudget()                   Continue/stop decision
│    │    └─ nudge message injection              Meta message to keep going
│    └─ Tool Execution
│         ├─ StreamingToolExecutor.getRemainingResults()
│         └─ runTools() (src/services/tools/toolOrchestration.ts)
│              ├─ partitionToolCalls()            Batch: concurrent-safe vs serial
│              ├─ runToolsConcurrently()           Max 10 concurrent read-only tools
│              └─ runToolsSerially()               Sequential for write tools
├─ processUserInput()                    Slash command routing (src/utils/processUserInput/)
├─ fetchSystemPromptParts()              Prompt assembly (src/utils/queryContext.ts)
└─ Cost tracking, transcript, file state caching

Tool Execution Pipeline (src/services/tools/toolExecution.ts)
├─ Zod v4 input validation (safeParse)
├─ validateInput() — tool-specific validation
├─ Speculative classifier check (Bash only, parallel with hooks)
├─ runPreToolUseHooks() — hook permission decisions
├─ canUseTool() — permission system
├─ tool.call() — actual execution
├─ runPostToolUseHooks() — post-execution hooks
└─ mapToolResultToToolResultBlockParam() — result mapping

AppState (src/state/)
├─ store.ts         35-line custom store (getState/setState/subscribe)
├─ AppStateStore.ts Type definitions + defaults (~570 lines)
└─ AppState.tsx     React provider, settings sync, bypass permissions check

Services
├─ API client       Multi-provider: Anthropic, Bedrock, Vertex, Foundry (src/services/api/)
├─ MCP client       stdio, SSE, streamable HTTP, WebSocket transports (src/services/mcp/)
├─ Analytics        Datadog + first-party OTel dual backend (src/services/analytics/)
├─ Compact          Full, partial, micro, reactive, snip, context collapse (src/services/compact/)
├─ Memory           extractMemories, SessionMemory, teamMemorySync (src/memdir/, src/services/)
├─ OAuth            Token management, keychain prefetch (src/utils/secureStorage/)
├─ Settings         5-layer cascade, remote managed settings (src/utils/settings/)
├─ Policy           Limits enforcement from remote config (src/services/policyLimits/)
└─ Plugins          Plugin loading, marketplace, bundled plugins (src/plugins/, src/utils/plugins/)

Permission System (src/utils/permissions/, src/types/permissions.ts)
├─ Permission modes  7: default, plan, acceptEdits, bypassPermissions, dontAsk, auto, bubble
├─ Rule engine       7 sources: userSettings, projectSettings, localSettings,
│                    flagSettings, policySettings, cliArg, command, session
│                    Priority: deny > ask > allow
├─ YOLO classifier   2-stage (fast XML + thinking), speculative start
├─ Bash classifier   AST-parsed + regex fallback, speculative parallel check
└─ Sandbox           bubblewrap (Linux) / seatbelt (macOS) + bare repo scrubbing
```

---

## 2. Core Data Types to Implement

### 2.1 Message Types

Messages are a discriminated union on the `type` field. The types are imported throughout the codebase from `src/types/message.js`:

```typescript
// Core message union (reconstructed from imports across query.ts, Tool.ts, toolExecution.ts)
type Message =
  | UserMessage          // User input + tool_result blocks
  | AssistantMessage     // Model response with content blocks
  | SystemMessage        // System-injected messages (warnings, errors, info)
  | AttachmentMessage    // Context injections (memory, hooks, CLAUDE.md)
  | ProgressMessage      // Tool progress events
  | TombstoneMessage     // Marks orphaned messages for removal (fallback cleanup)

// Additional stream-time types
type StreamEvent = { type: string; ... }      // API streaming events
type RequestStartEvent = { type: 'stream_request_start' }
type ToolUseSummaryMessage = { ... }          // Haiku-generated tool summaries
```

**Key fields on UserMessage** (from `createUserMessage` usage):
- `content`: string or ContentBlockParam[] (including tool_result blocks)
- `toolUseResult`: string summary of tool output
- `sourceToolAssistantUUID`: links tool result back to requesting assistant message
- `isMeta`: boolean — marks recovery/nudge messages (not user-authored)
- `imagePasteIds`: number[] — tracks pasted images for dedup

**Key fields on AssistantMessage** (from query.ts streaming):
- `message.content`: ContentBlockParam[] (text, tool_use, thinking, redacted_thinking)
- `message.usage`: token counts from API response
- `message.id`: API message ID
- `requestId`: API request ID
- `isApiErrorMessage`: boolean — flags synthetic error messages
- `apiError`: string — error classification ('max_output_tokens', 'invalid_request', etc.)
- `uuid`: internal UUID for message correlation

### 2.2 Tool<Input, Output, P>

The `Tool` type is a generic with ~35+ fields defined in `src/Tool.ts:362-500`:

```typescript
type Tool<
  Input extends AnyObject = AnyObject,    // Zod schema
  Output = unknown,
  P extends ToolProgressData = ToolProgressData,
> = {
  // Identity
  readonly name: string
  aliases?: string[]                       // Deprecated name support
  searchHint?: string                      // ToolSearch keyword matching (3-10 words)

  // Schema
  readonly inputSchema: Input              // Zod v4 schema (runtime validation)
  readonly inputJSONSchema?: ToolInputJSONSchema  // Direct JSON Schema for MCP tools
  outputSchema?: z.ZodType<unknown>

  // Core lifecycle
  call(args, context, canUseTool, parentMessage, onProgress?): Promise<ToolResult<Output>>
  description(input, options): Promise<string>
  validateInput?(input, context): Promise<ValidationResult>
  hasPermission?(input, context): Promise<PermissionResult>

  // Classification
  isConcurrencySafe(input): boolean        // Can run in parallel?
  isEnabled(): boolean                     // Available in current config?
  isReadOnly(input): boolean               // Read-only operation?
  isDestructive?(input): boolean           // Irreversible? (delete, overwrite, send)
  isSearchOrReadCommand?(input): { isSearch, isRead, isList? }  // UI collapse hint
  isOpenWorld?(input): boolean
  requiresUserInteraction?(): boolean

  // Execution control
  interruptBehavior?(): 'cancel' | 'block'  // Behavior on user interrupt
  maxResultSizeChars: number               // Infinity = never persist to disk

  // Observable input transform
  backfillObservableInput?(input): void    // Add legacy/derived fields for hooks/SDK

  // MCP-specific
  isMcp?: boolean
  isLsp?: boolean
  mcpInfo?: { serverName: string; toolName: string }

  // Deferred loading (ToolSearch)
  readonly shouldDefer?: boolean           // Requires ToolSearch before use
  readonly alwaysLoad?: boolean            // Never deferred, always in prompt

  // API hints
  readonly strict?: boolean                // Strict mode for tool schema adherence

  // Result mapping
  mapToolResultToToolResultBlockParam(data, toolUseID): ToolResultBlockParam
}
```

### 2.3 ToolResult<T>

```typescript
type ToolResult<T> = {
  data: T                                  // Tool-specific output
  newMessages?: (UserMessage | AssistantMessage | AttachmentMessage | SystemMessage)[]
  contextModifier?: (context: ToolUseContext) => ToolUseContext  // Only for non-concurrent tools
  mcpMeta?: {                              // MCP protocol metadata passthrough
    _meta?: Record<string, unknown>
    structuredContent?: Record<string, unknown>
  }
}
```

### 2.4 ToolUseContext

The central context object threaded through the entire system. ~59 fields organized into options, callbacks, and state:

```typescript
type ToolUseContext = {
  // Configuration (immutable within a query)
  options: {
    commands: Command[]
    debug: boolean
    mainLoopModel: string                  // Mutable: updated on fallback
    tools: Tools
    verbose: boolean
    thinkingConfig: ThinkingConfig
    mcpClients: MCPServerConnection[]
    mcpResources: Record<string, ServerResource[]>
    isNonInteractiveSession: boolean
    agentDefinitions: AgentDefinitionsResult
    maxBudgetUsd?: number
    customSystemPrompt?: string
    appendSystemPrompt?: string
    querySource?: QuerySource
    refreshTools?: () => Tools
  }

  // Abort control
  abortController: AbortController

  // File state
  readFileState: FileStateCache

  // AppState access (store bridge)
  getAppState(): AppState
  setAppState(f: (prev: AppState) => AppState): void
  setAppStateForTasks?: (f: (prev: AppState) => AppState) => void

  // UI callbacks (only wired in REPL mode)
  setToolJSX?: SetToolJSXFn
  addNotification?: (notif: Notification) => void
  appendSystemMessage?: (msg: SystemMessage) => void
  sendOSNotification?: (opts: { message; notificationType }) => void
  setInProgressToolUseIDs: (f: (prev: Set<string>) => Set<string>) => void
  setHasInterruptibleToolInProgress?: (v: boolean) => void
  setResponseLength: (f: (prev: number) => number) => void
  setStreamMode?: (mode: SpinnerMode) => void
  setSDKStatus?: (status: SDKStatus) => void
  onCompactProgress?: (event: CompactProgressEvent) => void

  // Elicitation (MCP protocol URL-based approval flow)
  handleElicitation?: (serverName, params, signal) => Promise<ElicitResult>

  // Message list (mutable — updated per iteration)
  messages: Message[]

  // Memory / skill state
  nestedMemoryAttachmentTriggers?: Set<string>
  loadedNestedMemoryPaths?: Set<string>
  dynamicSkillDirTriggers?: Set<string>
  discoveredSkillNames?: Set<string>

  // Limits
  fileReadingLimits?: { maxTokens?; maxSizeBytes? }
  globLimits?: { maxResults? }

  // Tracking
  queryTracking?: QueryChainTracking       // { chainId: string, depth: number }
  toolDecisions?: Map<string, { source; decision; timestamp }>
  contentReplacementState?: ContentReplacementState

  // Agent identity
  agentId?: AgentId                        // Only for subagents
  agentType?: string
  toolUseId?: string

  // History & attribution
  updateFileHistoryState: (updater) => void
  updateAttributionState: (updater) => void
  setConversationId?: (id: UUID) => void

  // Permissions (subagent-local)
  localDenialTracking?: DenialTrackingState
  requireCanUseTool?: boolean

  // Prompt support
  requestPrompt?: (sourceName, toolInputSummary?) => (request) => Promise<PromptResponse>
  pushApiMetricsEntry?: (ttftMs: number) => void
  openMessageSelector?: () => void

  // System prompt cache (fork sharing)
  renderedSystemPrompt?: SystemPrompt

  // Experimental
  userModified?: boolean
  preserveToolUseResults?: boolean
  criticalSystemReminder_EXPERIMENTAL?: string
}
```

### 2.5 QueryParams and Query Loop State

```typescript
// Entry parameters to query()
type QueryParams = {
  messages: Message[]
  systemPrompt: SystemPrompt
  userContext: { [k: string]: string }
  systemContext: { [k: string]: string }
  canUseTool: CanUseToolFn
  toolUseContext: ToolUseContext
  fallbackModel?: string
  querySource: QuerySource
  maxOutputTokensOverride?: number
  maxTurns?: number
  skipCacheWrite?: boolean
  taskBudget?: { total: number }           // API task_budget (beta)
  deps?: QueryDeps                         // Dependency injection for testing
}

// Mutable state carried between loop iterations
type State = {
  messages: Message[]
  toolUseContext: ToolUseContext
  autoCompactTracking: AutoCompactTrackingState | undefined
  maxOutputTokensRecoveryCount: number     // 0–3 multi-turn recovery attempts
  hasAttemptedReactiveCompact: boolean
  maxOutputTokensOverride: number | undefined
  pendingToolUseSummary: Promise<ToolUseSummaryMessage | null> | undefined
  stopHookActive: boolean | undefined
  turnCount: number
  transition: Continue | undefined         // Why previous iteration continued
}

// QueryConfig — immutable values snapshotted once at query() entry
type QueryConfig = {
  sessionId: SessionId
  gates: {
    streamingToolExecution: boolean
    emitToolUseSummaries: boolean
    isAnt: boolean
    fastModeEnabled: boolean
  }
}
```

### 2.6 AppState

The `AppState` type is ~570 lines in `src/state/AppStateStore.ts`. It wraps most fields in `DeepImmutable<>` with explicit escapes for mutable subsystems. Key slices:

```typescript
type AppState = DeepImmutable<{
  // Settings & config
  settings: SettingsJson                   // 5-layer merged settings
  verbose: boolean
  mainLoopModel: ModelSetting
  mainLoopModelForSession: ModelSetting

  // UI state
  statusLineText: string | undefined
  expandedView: 'none' | 'tasks' | 'teammates'
  isBriefOnly: boolean
  selectedIPAgentIndex: number
  coordinatorTaskIndex: number
  viewSelectionMode: 'none' | 'selecting-agent' | 'viewing-agent'
  footerSelection: FooterItem | null

  // Permissions
  toolPermissionContext: ToolPermissionContext

  // Agent & session
  agent: string | undefined
  kairosEnabled: boolean
  remoteSessionUrl: string | undefined
  remoteConnectionStatus: 'connecting' | 'connected' | 'reconnecting' | 'disconnected'

  // Bridge (IDE integration)
  replBridgeEnabled: boolean
  replBridgeConnected: boolean
  replBridgeSessionActive: boolean
  replBridgeConnectUrl: string | undefined
  // ... ~15 more bridge fields
}> & {
  // Mutable subsystems (excluded from DeepImmutable)
  tasks: { [taskId: string]: TaskState }
  agentNameRegistry: Map<string, AgentId>
  foregroundedTaskId?: string

  mcp: {
    clients: MCPServerConnection[]
    tools: Tool[]
    commands: Command[]
    resources: Record<string, ServerResource[]>
    pluginReconnectKey: number
  }

  plugins: {
    enabled: LoadedPlugin[]
    disabled: LoadedPlugin[]
    commands: Command[]
    errors: PluginError[]
    installationStatus: { marketplaces: [...]; plugins: [...] }
    needsRefresh: boolean
  }

  agentDefinitions: AgentDefinitionsResult
  fileHistory: FileHistoryState
  attribution: AttributionState
  todos: { [agentId: string]: TodoList }
  notifications: { current: Notification | null; queue: Notification[] }
  elicitation: { queue: ElicitationRequestEvent[] }
  thinkingEnabled: boolean | undefined
  sessionHooks: SessionHooksState
  teamContext?: { teamName; teammates; isLeader; ... }
  inbox: { messages: Array<{ id; from; text; timestamp; status; ... }> }
  promptSuggestion: { text; promptId; shownAt; acceptedAt; generationRequestId }
  speculation: SpeculationState
  denialTracking?: DenialTrackingState
  fastMode?: boolean
  advisorModel?: string
  effortValue?: EffortValue
  // ... computer use, REPL context, tungsten, bagel state
}
```

### 2.7 Permission Types

```typescript
// Permission modes — 7 total
type ExternalPermissionMode = 'acceptEdits' | 'bypassPermissions' | 'default' | 'dontAsk' | 'plan'
type InternalPermissionMode = ExternalPermissionMode | 'auto' | 'bubble'
type PermissionMode = InternalPermissionMode

// Rule sources — 7 origins
type PermissionRuleSource =
  | 'userSettings' | 'projectSettings' | 'localSettings'
  | 'flagSettings' | 'policySettings' | 'cliArg' | 'command' | 'session'

// Permission decision — discriminated union
type PermissionResult<Input> =
  | PermissionAllowDecision<Input>   // { behavior: 'allow', updatedInput?, userModified?, ... }
  | PermissionAskDecision<Input>     // { behavior: 'ask', message, pendingClassifierCheck?, ... }
  | PermissionDenyDecision           // { behavior: 'deny', message, decisionReason }
  | { behavior: 'passthrough', message, ... }

// Decision reason — rich discriminated union for audit trail
type PermissionDecisionReason =
  | { type: 'rule'; rule: PermissionRule }
  | { type: 'mode'; mode: PermissionMode }
  | { type: 'hook'; hookName; hookSource?; reason? }
  | { type: 'classifier'; classifier; reason }
  | { type: 'sandboxOverride'; reason: 'excludedCommand' | 'dangerouslyDisableSandbox' }
  | { type: 'subcommandResults'; reasons: Map<string, PermissionResult> }
  | { type: 'permissionPromptTool'; permissionPromptToolName; toolResult }
  | { type: 'asyncAgent'; reason }
  | { type: 'workingDir'; reason }
  | { type: 'safetyCheck'; reason; classifierApprovable }
  | { type: 'other'; reason }

// YOLO classifier result — 2-stage pipeline
type YoloClassifierResult = {
  thinking?: string
  shouldBlock: boolean
  reason: string
  model: string
  stage?: 'fast' | 'thinking'
  usage?: ClassifierUsage
  durationMs?: number
  stage1Usage?: ClassifierUsage
  stage2Usage?: ClassifierUsage
  // ... request IDs for audit joining
}

// Tool permission context — threaded through the system
type ToolPermissionContext = DeepImmutable<{
  mode: PermissionMode
  additionalWorkingDirectories: Map<string, AdditionalWorkingDirectory>
  alwaysAllowRules: ToolPermissionRulesBySource
  alwaysDenyRules: ToolPermissionRulesBySource
  alwaysAskRules: ToolPermissionRulesBySource
  isBypassPermissionsModeAvailable: boolean
  isAutoModeAvailable?: boolean
  strippedDangerousRules?: ToolPermissionRulesBySource
  shouldAvoidPermissionPrompts?: boolean
  awaitAutomatedChecksBeforeDialog?: boolean
  prePlanMode?: PermissionMode
}>
```

### 2.8 ThinkingConfig

```typescript
type ThinkingConfig =
  | { type: 'adaptive' }                  // Server-controlled thinking
  | { type: 'enabled'; budgetTokens: number }  // Fixed budget
  | { type: 'disabled' }                  // No thinking blocks
```

---

## 3. Control Flow Diagrams

### 3.1 Main Query Loop

The core agentic loop is an async generator in `src/query.ts`. Each iteration represents one model turn.

```
async function* queryLoop(params):
  // Immutable params destructured once
  { systemPrompt, userContext, systemContext, canUseTool, fallbackModel, querySource, maxTurns } = params
  deps = params.deps ?? productionDeps()

  // Mutable state object — reassigned at continue sites
  state = {
    messages: params.messages,
    toolUseContext: params.toolUseContext,
    autoCompactTracking: undefined,
    maxOutputTokensRecoveryCount: 0,
    hasAttemptedReactiveCompact: false,
    maxOutputTokensOverride: params.maxOutputTokensOverride,
    pendingToolUseSummary: undefined,
    stopHookActive: undefined,
    turnCount: 1,
    transition: undefined,
  }
  budgetTracker = createBudgetTracker()     // TOKEN_BUDGET feature
  config = buildQueryConfig()                // Snapshot env/statsig once
  pendingMemoryPrefetch = startRelevantMemoryPrefetch(messages, toolUseContext)

  while (true):
    // Destructure state
    { messages, toolUseContext, autoCompactTracking, maxOutputTokensRecoveryCount,
      hasAttemptedReactiveCompact, maxOutputTokensOverride, pendingToolUseSummary,
      stopHookActive, turnCount } = state

    // Start skill discovery prefetch (non-blocking)
    pendingSkillPrefetch = startSkillDiscoveryPrefetch(messages, toolUseContext)

    yield { type: 'stream_request_start' }

    // ── Phase 1: Context Preparation ──────────────────────────────────

    // Increment query chain tracking
    queryTracking = { chainId, depth: depth + 1 }

    // 1a. Strip pre-compact messages
    messagesForQuery = getMessagesAfterCompactBoundary(messages)

    // 1b. Per-message tool result budget enforcement
    messagesForQuery = applyToolResultBudget(messagesForQuery, contentReplacementState)

    // 1c. Snip compact (HISTORY_SNIP feature) — reclaim tokens from old turns
    if HISTORY_SNIP:
      { messages: messagesForQuery, tokensFreed: snipTokensFreed } = snipCompactIfNeeded(messagesForQuery)

    // 1d. Microcompact — short-lived context reduction / cache editing
    { messages: messagesForQuery, compactionInfo } = microcompact(messagesForQuery, toolUseContext)

    // 1e. Context collapse (CONTEXT_COLLAPSE feature) — staged folding
    if CONTEXT_COLLAPSE:
      { messages: messagesForQuery } = applyCollapsesIfNeeded(messagesForQuery, toolUseContext)

    // 1f. Proactive autocompact — full compaction via forked agent
    { compactionResult, consecutiveFailures } = autocompact(messagesForQuery, toolUseContext, ...)
    if compactionResult:
      yield compact_boundary_messages
      messagesForQuery = buildPostCompactMessages(compactionResult)

    // 1g. Block at hard limit (only when auto-compact OFF and no recovery path)
    if !compactionResult && !reactiveCompactEnabled && isAtBlockingLimit:
      yield error; return { reason: 'blocking_limit' }

    // ── Phase 2: Model Streaming ──────────────────────────────────────

    streamingToolExecutor = new StreamingToolExecutor(tools, canUseTool, toolUseContext)
    toolUseBlocks = []
    needsFollowUp = false
    attemptWithFallback = true

    while (attemptWithFallback):
      attemptWithFallback = false
      try:
        for await message in callModel(messages, systemPrompt, tools, ...):
          // Backfill observable input on tool_use blocks (clone, don't mutate)
          // Withhold recoverable errors (prompt-too-long, max-output-tokens)
          if !withheld: yield message

          if message.type == 'assistant':
            assistantMessages.push(message)
            for toolBlock in message.content.filter(type == 'tool_use'):
              toolUseBlocks.push(toolBlock)
              needsFollowUp = true
              streamingToolExecutor.addTool(toolBlock, message)

          // Yield completed streaming tool results inline
          for result in streamingToolExecutor.getCompletedResults():
            yield result.message

      catch FallbackTriggeredError:
        currentModel = fallbackModel
        attemptWithFallback = true
        // Tombstone orphaned messages, reset state, create fresh executor
        yield tombstones; clear(assistantMessages, toolResults, toolUseBlocks)

    // ── Phase 3: Post-Streaming ───────────────────────────────────────

    // 3a. Fire background post-sampling hooks
    executePostSamplingHooks(messages + assistantMessages, systemPrompt, ...)

    // 3b. Handle abort
    if aborted:
      consume streamingToolExecutor.getRemainingResults()  // Synthetic tool_results
      yield interruption; return { reason: 'aborted_streaming' }

    // 3c. Yield pending tool use summary from previous turn
    if pendingToolUseSummary: yield await pendingToolUseSummary

    // 3d. No follow-up needed → recovery + stop hooks + budget check
    if !needsFollowUp:
      // Prompt-too-long recovery cascade
      if isWithheld413:
        if CONTEXT_COLLAPSE: try collapseDrain → continue if committed
        if reactiveCompact: try compact → continue if succeeded
        yield error; return { reason: 'prompt_too_long' }

      // Max output tokens recovery
      if isWithheldMaxOutputTokens:
        if !override: try escalate to 64K → continue
        if recoveryCount < 3: inject resume message → continue
        yield withheld error

      // Stop hooks — validate model output
      stopHookResult = yield* handleStopHooks(messages, assistantMessages, ...)
      if stopHookResult.preventContinuation: return { reason: 'stop_hook_prevented' }
      if stopHookResult.blockingErrors: state = { ..., messages + errors }; continue

      // Token budget check (TOKEN_BUDGET feature)
      if TOKEN_BUDGET:
        decision = checkTokenBudget(tracker, budget, turnTokens)
        if decision.action == 'continue': inject nudge; continue

      return { reason: 'completed' }

    // ── Phase 4: Tool Execution ───────────────────────────────────────

    toolUpdates = streamingToolExecutor
      ? streamingToolExecutor.getRemainingResults()
      : runTools(toolUseBlocks, assistantMessages, canUseTool, toolUseContext)

    for await update in toolUpdates:
      yield update.message
      if hook_stopped_continuation: shouldPreventContinuation = true
      if update.newContext: updatedToolUseContext = update.newContext

    // Generate tool use summary (Haiku, non-blocking)
    nextPendingToolUseSummary = generateToolUseSummary(toolInfos)

    if aborted: yield interruption; return { reason: 'aborted_tool' }
    if shouldPreventContinuation: return { reason: 'hook_prevented_continuation' }

    // ── Phase 5: Attachments & Queue ──────────────────────────────────

    attachments = getAttachmentMessages()        // Memory, CLAUDE.md, context
    queuedCommands = getCommandsByMaxPriority()  // /command queue
    consume pendingMemoryPrefetch → filter duplicate memory attachments
    consume pendingSkillPrefetch → skill discovery attachments
    refreshTools()                                // MCP reconnections

    // ── Phase 6: Turn Boundary ────────────────────────────────────────

    if ++turnCount > maxTurns: yield max_turns_reached; return

    state = {
      messages: messagesForQuery + assistantMessages + toolResults + attachments + queue,
      toolUseContext: updatedToolUseContext,
      autoCompactTracking: tracking,
      maxOutputTokensRecoveryCount: 0,
      hasAttemptedReactiveCompact: false,
      maxOutputTokensOverride: undefined,
      pendingToolUseSummary: nextPendingToolUseSummary,
      stopHookActive: undefined,
      turnCount,
      transition: { reason: 'tool_use' },
    }
    continue
```

### 3.2 Tool Execution Pipeline

```
async function checkPermissionsAndCallTool(tool, toolUseID, input, context, canUseTool, ...):

  // Step 1: Zod schema validation
  parsedInput = tool.inputSchema.safeParse(input)
  if !parsedInput.success:
    // Check if deferred tool schema wasn't sent → hint to use ToolSearch
    hint = buildSchemaNotSentHint(tool, messages, tools)
    return InputValidationError(formatZodError + hint)

  // Step 2: Tool-specific input validation
  isValidCall = tool.validateInput?.(parsedInput.data, context)
  if isValidCall?.result === false: return ValidationError(isValidCall.message)

  // Step 3: Speculative classifier check (Bash only — parallel with hooks)
  if tool.name == 'Bash' && 'command' in input:
    startSpeculativeClassifierCheck(command, permContext, signal)

  // Step 4: Backfill observable input (clone for hooks, preserve original for call)
  callInput = parsedInput.data
  backfilledClone = { ...parsedInput.data }
  tool.backfillObservableInput?.(backfilledClone)
  processedInput = backfilledClone  // Used for hooks/permissions

  // Step 5: Pre-tool-use hooks
  for result in runPreToolUseHooks(context, tool, processedInput, toolUseID, ...):
    switch result.type:
      'message': collect result messages
      'hookPermissionResult': override permission decision
      'hookUpdatedInput': update processedInput for permission flow
      'preventContinuation': flag to stop after this tool
      'stop': return early with tool_result error

  // Step 6: Permission check
  if hookPermissionResult:
    permResult = resolveHookPermissionDecision(hookPermissionResult, ...)
  else:
    permResult = canUseTool(tool, processedInput, context)

  switch permResult.behavior:
    'deny': return PermissionDenied(permResult.message)
    'ask':
      // In interactive mode: show permission dialog
      // In non-interactive: auto-deny
      // If pendingClassifierCheck: race classifier vs user response
    'allow': proceed (maybe with updatedInput)

  // Step 7: Execute tool
  startSessionActivity()
  startToolExecutionSpan()
  try:
    result = tool.call(callInput, context, canUseTool, parentMessage, onProgress)
  catch error:
    runPostToolUseFailureHooks(context, tool, callInput, error)
    return formatError(error)
  finally:
    stopSessionActivity()
    endToolExecutionSpan()

  // Step 8: Post-tool-use hooks
  for hookResult in runPostToolUseHooks(context, tool, callInput, result):
    collect hook messages
    if hook_stopped: shouldPreventContinuation = true

  // Step 9: Map result to API format
  resultBlock = tool.mapToolResultToToolResultBlockParam?.(result.data, toolUseID)
    ?? processToolResultBlock(result.data, toolUseID, tool)

  return [resultMessage, ...hookMessages, ...contextModifiers]
```

### 3.3 Permission Decision Flow

```
function hasPermissionsToUseTool(tool, input, permCtx):

  // 1. Deny rules always win (from ALL 7+ sources)
  for source in [policySettings, flagSettings, projectSettings, localSettings, userSettings, cliArg, command, session]:
    if permCtx.alwaysDenyRules[source]?.some(rule => matchesToolAndContent(tool, input, rule)):
      return { behavior: 'deny', decisionReason: { type: 'rule', rule } }

  // 2. Ask rules override allow
  for source in allSources:
    if permCtx.alwaysAskRules[source]?.some(rule => matches(tool, input, rule)):
      return { behavior: 'ask', message: 'Rule requires approval' }

  // 3. Allow rules
  for source in allSources:
    if permCtx.alwaysAllowRules[source]?.some(rule => matches(tool, input, rule)):
      return { behavior: 'allow', decisionReason: { type: 'rule', rule } }

  // 4. Mode-specific fallback
  switch permCtx.mode:
    'plan':
      return tool.isReadOnly(input) ? ALLOW : DENY

    'acceptEdits':
      return isFileEditTool(tool) ? ALLOW : ASK

    'bypassPermissions':
      if killswitched: return ASK  // Remote disable via policy
      return ALLOW

    'dontAsk':
      return DENY

    'auto':
      // 2-stage YOLO classifier
      // Stage 1: fast XML check against safe allowlist
      if safeAllowlistMatch(tool, input): return ALLOW
      // Stage 2: thinking classifier with full conversation context
      result = invokeYoloClassifier(tool, input, conversationHistory)
      return result.shouldBlock ? ASK : ALLOW

    'bubble':
      // Delegate to parent process (coordinator workers)
      return { behavior: 'passthrough', ... }

    'default':
      return ASK
```

### 3.4 Memory System Flow

```
On startup:
  // CLAUDE.md files — hierarchical, directory-scoped
  loadCLAUDEMdFiles(cwd, additionalDirs)
    → scan .claude/settings.md, CLAUDE.md, CLAUDE.local.md at cwd + parents + home
    → inject as system prompt parts (sorted by specificity)

  // MEMORY.md — user-authored persistent memory
  loadMemoryPrompt(memdir)
    → read ~/.claude/MEMORY.md (capped 200 lines / 25KB)
    → inject into system prompt

Per turn (attachment system):
  // Relevant memory prefetch — fires once per user turn
  startRelevantMemoryPrefetch(messages, toolUseContext)
    → await settling (non-blocking during model stream)
    → findRelevantMemories(query) via Sonnet side-query
    → select up to 5 files from memory directory
    → filterDuplicateMemoryAttachments()
    → inject as AttachmentMessages

  // Nested memory triggers — directory-scoped CLAUDE.md injection
  nestedMemoryAttachmentTriggers: Set<string>
    → when tool reads/writes in new directory, check for CLAUDE.md
    → inject as nested_memory attachment (deduplicated via loadedNestedMemoryPaths)

Post-sampling (background):
  // Session memory extraction — periodic
  if sessionMemoryThresholdMet:
    // Thresholds: 10K tokens initial, 5K between, 3+ tool calls
    runForkedAgent(extractSessionMemory)
      → restricted to FileEditTool on session memory file
      → forked agent shares parent prompt cache (NO_TOOLS_PREAMBLE)

End of query loop (background):
  // Auto-memory extraction
  if extractionEnabled && turnsSinceLastExtraction > threshold:
    runForkedAgent(extractMemories)
      → restricted tools within memory directory (~/.claude/)
      → writes to MEMORY.md or topic-specific files

On compaction:
  // 9-section summary via forked agent
  compactConversation()
    → forked agent with shared prompt cache (NO_TOOLS_PREAMBLE)
    → produces structured summary
    → post-compact re-injection of CLAUDE.md + memory files
```

---

## 4. Module Dependency Map

Key import chains showing how the system connects:

```
── Entrypoints ──────────────────────────────────────────────────────
cli.tsx
  → main.tsx (dynamic import after fast-path checks)
  → replLauncher.tsx → REPL component (Ink render)
  → init.ts (memoized one-time setup)

── Query Pipeline ───────────────────────────────────────────────────
main.tsx
  → QueryEngine.ts (conversation lifecycle)
    → query.ts (core loop)
      → services/api/claude.ts (callModel, streaming)
      → services/api/withRetry.ts (FallbackTriggeredError)
    → utils/processUserInput/processUserInput.ts (slash commands)
      → commands.ts (command registry)
    → utils/queryContext.ts → context.ts (system prompt assembly)
    → cost-tracker.ts (usage/cost tracking)
    → utils/sessionStorage.ts (transcript persistence)

── Tool System ──────────────────────────────────────────────────────
query.ts
  → services/tools/toolOrchestration.ts (partition + run)
    → services/tools/toolExecution.ts (validate + permission + call)
      → Tool.ts (type definitions + matching)
        ← tools.ts (registration, getTools/getAllBaseTools)
          ← tools/*/ (41 tool implementations)
  → services/tools/StreamingToolExecutor.ts (parallel during stream)
  → services/tools/toolHooks.ts (pre/post hooks)

── State ────────────────────────────────────────────────────────────
state/store.ts (35-line custom store: getState/setState/subscribe)
  → state/AppStateStore.ts (type definitions, getDefaultAppState)
  → state/AppState.tsx (React provider, useSyncExternalStore)

── Permissions ──────────────────────────────────────────────────────
types/permissions.ts (pure types — breaks import cycles)
  ← utils/permissions/ (runtime logic)
  ← hooks/useCanUseTool.ts (CanUseToolFn factory)
  ← tools/BashTool/bashPermissions.ts (speculative classifier)

── Context Pipeline ─────────────────────────────────────────────────
query.ts
  → utils/toolResultStorage.ts (applyToolResultBudget)
  → services/compact/snipCompact.ts [HISTORY_SNIP]
  → services/compact/microcompact/ [per-message compaction]
  → services/contextCollapse/ [CONTEXT_COLLAPSE]
  → services/compact/autoCompact.ts → compact.ts (full compaction)
  → services/compact/reactiveCompact.ts (413 recovery)

── Analytics ────────────────────────────────────────────────────────
services/analytics/index.ts (logEvent entrypoint)
  → services/analytics/sink.ts (dual backend router)
  → services/analytics/growthbook.ts (feature flags)
  → cli/transports/SerialBatchEventUploader.ts

── Memory ───────────────────────────────────────────────────────────
memdir/memdir.ts (loadMemoryPrompt, memory directory scanning)
  → memdir/paths.ts (memory file path resolution)
  → memdir/teamMemory.ts (team memory sync)
  → services/extractMemories/ (background extraction)
  → services/SessionMemory/ (session-scoped extraction)
  → utils/attachments.ts (memory prefetch + injection)

── MCP ──────────────────────────────────────────────────────────────
services/mcp/client.ts (getMcpToolsCommandsAndResources)
  → services/mcp/types.ts (MCPServerConnection, transport types)
  → services/mcp/normalization.ts (name normalization)
  → services/mcp/elicitationHandler.ts (URL-based approval)
```

---

## 5. Build System Requirements

### 5.1 TypeScript Configuration

```jsonc
// tsconfig.json key settings (verified from repository artifacts)
{
  "compilerOptions": {
    "module": "nodenext",               // ESM modules
    "moduleResolution": "bundler",      // Bundler-style resolution
    "target": "ES2022",
    "jsx": "react-jsx",
    "paths": {
      "src/*": ["./src/*"],
      "@ant/*": ["./src/*"],            // Internal alias
      "bun:bundle": ["./typings/bun-bundle.d.ts"],  // Feature flag shim
      "bun:ffi": ["./typings/bun-ffi.d.ts"]
    }
  }
}
```

### 5.2 Build Pipeline (esbuild)

From `build.mjs`:

- **Tool**: esbuild (transpile-only, no bundling — preserves directory structure)
- **Output**: `dist/` mirroring `src/` as runnable ESM JavaScript
- **Entry CLI**: `cli.js` at root loads `dist/entrypoints/cli.js`
- **Defines**: `MACRO.VERSION`, `MACRO.PACKAGE_URL`, `MACRO.NATIVE_PACKAGE_URL`, `MACRO.FEEDBACK_CHANNEL`
- **Shims**: `bun:bundle` → feature() always returns false; `bun:ffi` → no-op exports
- **JSX**: Automatic runtime (`react-jsx`)
- **Target**: Node 18+

### 5.3 Compile-Time Feature Flags

```typescript
import { feature } from 'bun:bundle'

// Usage pattern — MUST be in if/ternary condition for DCE
if (feature('REACTIVE_COMPACT')) {
  const module = require('./services/compact/reactiveCompact.js')
  // ...
}

// External builds: feature() → false, entire block tree-shaken
// Internal builds: feature() → true at compile time
```

Feature flags identified through architecture analysis: `REACTIVE_COMPACT`, `CONTEXT_COLLAPSE`, `HISTORY_SNIP`, `CACHED_MICROCOMPACT`, `EXPERIMENTAL_SKILL_SEARCH`, `TEMPLATES`, `BG_SESSIONS`, `TOKEN_BUDGET`, `VOICE_MODE`, `COORDINATOR_MODE`, `KAIROS`, `ABLATION_BASELINE`, `CHICAGO_MCP`, `DUMP_SYSTEM_PROMPT`, `TRANSCRIPT_CLASSIFIER`.

### 5.4 Key Dependencies

| Dependency | Purpose |
|-----------|---------|
| Zod v4 | Schema validation (tool inputs, settings, configs) |
| React + Ink | Terminal UI rendering (custom reconciler) |
| Commander.js | CLI argument parsing (`@commander-js/extra-typings`) |
| GrowthBook SDK | Runtime feature flags (statsig-compatible) |
| OpenTelemetry SDK | Telemetry / session tracing |
| Anthropic SDK | API client (`@anthropic-ai/sdk`) |
| yoga-layout | Terminal layout engine (used by Ink) |
| lodash-es | Utility functions (ESM tree-shakeable) |
| chalk | Terminal colors |
| strip-ansi | ANSI escape removal |
| shell-quote | Bash command parsing |

---

## 6. Key Implementation Decisions Summary

### 6.1 Query Loop: While-True State Machine

**Choice**: `while (true)` loop with a mutable `State` object, not recursive function calls.

**Why**: Prevents stack overflow on long agentic sessions (100+ turns). Enables explicit state transitions — each `continue` site creates a new `State` object with a `transition` field documenting why the loop continued. The generator (`async function*`) pattern allows streaming results to the caller without buffering.

### 6.2 File Edits: String Find-Replace, Not Diff/Patch

**Choice**: `FileEditTool` uses exact string matching (`old_string` → `new_string`), not unified diffs or patch format.

**Why**: LLMs are unreliable at generating correct line-numbered diffs. String find-replace is self-validating — if `old_string` doesn't match exactly, the tool fails with a clear error. This eliminates an entire class of silent corruption from off-by-one line numbers.

### 6.3 Memory Recall: LLM Side-Query, Not Embedding Search

**Choice**: Relevant memory retrieval uses a Sonnet API call as a side-query to select from the memory directory, not vector embeddings.

**Why**: Better cross-domain association. Embedding search requires maintaining an index and fails when the query doesn't share lexical similarity with stored memories. An LLM can reason about semantic relationships ("the user prefers TypeScript" is relevant to a Python question about language choice).

### 6.4 Compaction: Forked Agent with Cache Sharing

**Choice**: Conversation compaction runs as a forked agent that shares the parent's prompt cache, uses `NO_TOOLS_PREAMBLE` to prevent tool use during summarization.

**Why**: Cache sharing means the compaction agent doesn't pay for re-encoding the system prompt. `NO_TOOLS_PREAMBLE` prevents the summarizer from hallucinating tool calls while producing the summary. The forked agent produces a structured 9-section summary that preserves key context across the compaction boundary.

### 6.5 Permissions: Deny-Rules-Always-Win

**Choice**: Deny rules from any source take absolute priority — no hook, classifier, or mode can override a deny rule.

**Why**: Inviolable security boundary. Policy administrators can set deny rules (via `policySettings`) knowing they cannot be bypassed by user settings, session overrides, or auto-mode classifiers. The priority order `deny > ask > allow` is evaluated across all 7+ sources before any mode-specific logic runs.

### 6.6 Bash Security: AST + Regex Dual Path

**Choice**: Bash command safety analysis uses shell-quote AST parsing as the primary path with regex fallback for unparseable commands.

**Why**: AST parsing gives accurate decomposition of compound commands, redirections, and subshells. But some valid bash (heredocs, complex quoting) defeats shell-quote. The regex path provides a conservative fallback that errs toward `ask` rather than silently allowing. The speculative classifier check starts in parallel with hook execution to hide latency.

### 6.7 Feature Flags: Compile-Time Dead Code Elimination

**Choice**: `feature('FLAG_NAME')` from `bun:bundle` is evaluated at build time. External builds get `false` and the code is physically removed by esbuild.

**Why**: Security-sensitive code (internal tools, classifiers, ablation infrastructure) is not just disabled but absent from distributed builds. This eliminates the risk of runtime flag manipulation enabling internal-only functionality. Build.mjs shims `bun:bundle` to always return `false` for the external build.

### 6.8 State: 35-Line Custom Store

**Choice**: A 35-line `createStore()` function instead of Zustand, Jotai, or Redux.

**Why**: Independence from React lifecycle. The store must be accessible from non-React code paths: the Bridge (IDE integration), CCR (Claude Code Remote), SDK mode, and background task runners. `useSyncExternalStore` connects it to React when needed. The store is simply `{ getState, setState, subscribe }` with `Object.is` equality check and a listener set.

### 6.9 Tool Defaults: Fail-Closed

**Choice**: Unknown tools return errors. Permission checks default to `ask` (not `allow`). Tool input validation is mandatory (Zod safeParse). Aborted operations yield synthetic `tool_result` blocks with `is_error: true`.

**Why**: Security by default. An LLM hallucinating a tool name gets a clear error rather than silent pass-through. A tool missing a permission handler defaults to prompting rather than auto-allowing. Every tool_use block in the conversation gets a corresponding tool_result — the API requires this, and missing results cause protocol errors.

### 6.10 Analytics: No-String Metadata Type

**Choice**: Analytics metadata values are typed as `AnalyticsMetadata_I_VERIFIED_THIS_IS_NOT_CODE_OR_FILEPATHS` — a branded string type that requires explicit casting.

**Why**: Compile-time PII prevention. The long type name is intentional — every `as AnalyticsMetadata_I_VERIFIED_THIS_IS_NOT_CODE_OR_FILEPATHS` cast is a code-review checkpoint where the developer affirms the value doesn't contain user code, file paths, or secrets. This makes accidental PII logging a type error rather than a runtime leak.

---

## Appendix A: File Counts by Directory

| Directory | Files | Primary Concern |
|-----------|------:|-----------------|
| `utils/` | 564 | Cross-cutting: permissions, bash security, telemetry, plugins, settings, hooks |
| `components/` | 389 | UI: messages, permissions dialogs, prompt input, agents |
| `commands/` | 207 | 86+ slash commands |
| `tools/` | 184 | 41 tool implementations |
| `services/` | 130 | API, MCP, compact, analytics, OAuth, LSP |
| `hooks/` | 104 | React hooks |
| `ink/` | 96 | Terminal UI framework |
| `bridge/` | 31 | IDE integration |
| `constants/` | 21 | Static values |
| `skills/` | 20 | Bundled skill loader |
| `state/` | 6 | App state management |
| **Total** | **~1,915** | |

## Appendix B: Transition Reasons

The query loop's `State.transition` field documents every reason the loop continued rather than returning. These form the complete set of retry/continue paths:

| Transition Reason | Trigger |
|-------------------|---------|
| `tool_use` | Model produced tool_use blocks requiring follow-up |
| `reactive_compact_retry` | Prompt-too-long recovered via reactive compaction |
| `collapse_drain_retry` | Context collapse drained staged collapses |
| `max_output_tokens_escalate` | Retrying with 64K token limit |
| `max_output_tokens_recovery` | Multi-turn continuation after truncation (up to 3×) |
| `stop_hook_blocking` | Stop hook injected blocking errors requiring retry |
| `token_budget_continuation` | Token budget not exhausted, nudge injected |

