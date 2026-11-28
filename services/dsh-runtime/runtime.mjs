import { z } from 'zod'
import { randomUUID } from 'node:crypto'
import { Context } from '@deepseek-ai/cordis'
import SessionStore, { interruptedTurnClosers } from '@deepseek-ai/dsh-session'
import SessionProjections from '@deepseek-ai/dsh-session-projection'
import LlmRuntime, { LlmAdapter, LlmError, createUserMessage, createToolResultMessage } from '@deepseek-ai/dsh-llm'
import SystemPrompt, { TOOL_ORDER_REST } from '@deepseek-ai/dsh-system-prompt'
import Tools from '@deepseek-ai/dsh-tools'
import Agents from '@deepseek-ai/dsh-agent'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import TokenMeter from '@deepseek-ai/dsh-token-meter'
import BasicCompaction from '@deepseek-ai/dsh-compaction-basic'

export const protocolVersion = 1
export const maximumFrameBytes = 16 * 1024 * 1024

export class RuntimeError extends Error {
  constructor(code) {
    super(code)
    this.code = code
  }
}

function requireValue(condition, code = 'invalid_request') {
  if (!condition) throw new RuntimeError(code)
}

function plainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function text(value) {
  return typeof value === 'string'
}

function clone(value) {
  return JSON.parse(JSON.stringify(value))
}

function normalizeStart(start) {
  requireValue(plainObject(start) && start.type === 'start')
  requireValue(text(start.systemPrompt) && text(start.prompt))
  requireValue(Number.isSafeInteger(start.contextTokens) && start.contextTokens > 0)
  requireValue(Number.isSafeInteger(start.outputTokens) && start.outputTokens > 0 && start.outputTokens < start.contextTokens)
  requireValue(Array.isArray(start.tools) && start.tools.length <= 256)
  const names = new Set()
  for (const tool of start.tools) {
    requireValue(plainObject(tool) && text(tool.name) && /^[A-Za-z0-9_-]{1,128}$/.test(tool.name))
    requireValue(!names.has(tool.name) && text(tool.description) && plainObject(tool.parameters))
    names.add(tool.name)
  }
  const snapshot = start.snapshot ?? null
  const results = start.toolResults ?? []
  requireValue(Array.isArray(results))
  if (snapshot !== null) {
    requireValue(plainObject(snapshot) && snapshot.version === protocolVersion && text(snapshot.sessionId), 'invalid_snapshot')
    requireValue(Array.isArray(snapshot.events) && snapshot.events.length > 0 && plainObject(snapshot.pending), 'invalid_snapshot')
    requireValue(Array.isArray(snapshot.pending.calls) && snapshot.pending.calls.length > 0 && plainObject(snapshot.pending.log), 'invalid_snapshot')
    requireValue(results.length === snapshot.pending.calls.length, 'result_mismatch')
    const ids = new Set()
    for (const [index, call] of snapshot.pending.calls.entries()) {
      const result = results[index]
      requireValue(plainObject(call) && text(call.id) && text(call.name) && text(call.arguments) && Number.isSafeInteger(call.seq), 'invalid_snapshot')
      requireValue(!ids.has(call.id), 'invalid_snapshot')
      ids.add(call.id)
      requireValue(plainObject(result) && result.tool_call_id === call.id && text(result.content), 'result_mismatch')
      requireValue(result.isError === undefined || typeof result.isError === 'boolean', 'result_mismatch')
    }
  } else requireValue(results.length === 0, 'result_mismatch')
  return { ...clone(start), snapshot: clone(snapshot), toolResults: clone(results) }
}

function wireMessage(message) {
  const chunks = []
  const reasoning = []
  const calls = []
  for (const block of message.content) {
    if (block.type === 'text') chunks.push(block.text)
    else if (block.type === 'reasoning') reasoning.push(block.text)
    else if (block.type === 'tool-call') calls.push({ id: block.id, name: block.name, arguments: block.arguments })
    else if (block.type === 'tool-addition') chunks.push(`Tool now available: ${block.toolName}`)
    else if (block.type === 'tool-removal') chunks.push(`Tool no longer available: ${block.toolName}`)
    else throw new RuntimeError('unsupported_content')
  }
  const result = { role: message.role === 'developer' ? 'user' : message.role, content: chunks.join('\n') }
  if (calls.length) result.tool_calls = calls
  if (reasoning.length) result.reasoning_content = reasoning.join('\n')
  if (message.role === 'tool') result.tool_call_id = message.toolCallId
  return result
}

class HostAdapter extends LlmAdapter {
  constructor(start, model) {
    super()
    this.start = start
    this.model = model
  }

  async resolveModel(provider, model) {
    return {
      provider, id: model, name: model,
      inputModalities: ['text'],
      context: { contextWindow: this.start.contextTokens },
      defaultMaxTokens: this.start.outputTokens
    }
  }

  async *stream(options) {
    const messages = options.messages.map(wireMessage)
    if (options.system) messages.unshift({ role: 'system', content: options.system })
    const request = {
      type: 'model', id: randomUUID(), messages,
      tools: options.tools ?? [],
      toolChoice: options.purpose === 'compaction' ? 'none' : 'auto',
      purpose: options.purpose ?? 'conversation'
    }
    const response = await this.model(request, options.signal)
    if (response.type === 'model_error') {
      throw LlmError.fromFailure({ code: text(response.code) ? response.code : 'provider_error', message: 'The model request failed.' })
    }
    requireValue(response.type === 'model_result' && text(response.content) && Array.isArray(response.tool_calls ?? []), 'invalid_model_response')
    const calls = response.tool_calls ?? []
    const ids = new Set()
    for (const call of calls) {
      requireValue(plainObject(call) && text(call.id) && call.id.length > 0 && !ids.has(call.id), 'invalid_model_response')
      requireValue(text(call.name) && call.name.length > 0 && text(call.arguments), 'invalid_model_response')
      ids.add(call.id)
    }
    const finish = response.finish_reason
    requireValue(['stop', 'tool_calls', 'length'].includes(finish), 'invalid_model_response')
    requireValue(finish === 'length' || (finish === 'tool_calls') === (calls.length > 0), 'invalid_model_response')
    let index = 0
    const blocks = []
    if (text(response.reasoning_content) && response.reasoning_content) blocks.push({ type: 'reasoning', text: response.reasoning_content })
    if (response.content) blocks.push({ type: 'text', text: response.content })
    for (const call of calls) blocks.push({ type: 'tool-call', ...call })
    for (const block of blocks) {
      yield { type: 'block-start', index, blockType: block.type }
      yield { type: 'block-end', index, block }
      index += 1
    }
    yield { type: 'finish', reason: { kind: finish === 'tool_calls' ? 'tool-calls' : finish === 'length' ? 'max-tokens' : 'stop' } }
  }
}

export async function advance(input, model, signal = new AbortController().signal) {
  const start = normalizeStart(input)
  signal.throwIfAborted()
  const ctx = new Context()
  let events = start.snapshot?.events ?? []
  const sessionId = start.snapshot?.sessionId ?? randomUUID()
  const boundary = Promise.withResolvers()
  let handle
  let end
  let failure
  let yielded = false
  let agent
  const abort = () => {
    if (agent) agent.cancel({ kind: 'parent' })
  }
  const snapshot = pending => ({ version: protocolVersion, sessionId, events: clone(events), pending })
  try {
    await ctx.plugin(SessionProjections)
    const capture = await ctx.sessionProjections.register({
      key: 'tandemHostSnapshot', stateVersion: 1, stateSchema: z.array(z.unknown()),
      init: () => [], apply: (state, event) => [...state, event]
    })
    await ctx.plugin(SessionStore)
    await ctx.plugin(LlmRuntime)
    await ctx.plugin(SystemPrompt, { includeHarnessIdentity: false, includeRuntimeContext: false, personaPrefix: '', toolOrder: [...start.tools.map(tool => tool.name), TOOL_ORDER_REST] })
    await ctx.plugin(Tools)
    await ctx.plugin(Agents)
    await ctx.plugin(TokenMeter)
    ctx.llm.registerAdapter(['tandem'], new HostAdapter(start, model))
    ctx.on('session/event', (session, event) => {
      if (session.id !== sessionId) return
      if (event.type === 'turn/end') end = event.data.reason
    })
    ctx.on('agent/error', event => { failure = event.error })
    ctx.tools.setExecutor({
      describe(definitions) {
        return { schemas: definitions.map(({ name, description, parameters }) => ({ name, description, parameters })) }
      },
      async execute(batch) {
        requireValue(!yielded && batch.agent && batch.log && batch.calls.length > 0, 'invalid_tool_batch')
        const ids = new Set()
        const calls = batch.calls.map(call => {
          requireValue(!ids.has(call.id), 'duplicate_tool_call')
          ids.add(call.id)
          const seq = batch.agent.session.append('tool/call', { ...batch.log, callId: call.id, name: call.name, arguments: call.arguments }).seq
          return { id: call.id, name: call.name, arguments: call.arguments, seq }
        })
        events = capture.stateOf(batch.agent.session)
        yielded = true
        const assistant = batch.agent.session.deriveMessages().findLast(message => message.role === 'assistant')
        const content = assistant?.content.filter(block => block.type === 'text').map(block => block.text).join('\n') ?? ''
        boundary.resolve({ type: 'boundary', snapshot: snapshot({ calls, log: batch.log }), toolCalls: calls.map(({ seq, ...call }) => call), content })
        await new Promise((_, reject) => {
          if (batch.signal.aborted) reject(batch.signal.reason)
          else batch.signal.addEventListener('abort', () => reject(batch.signal.reason), { once: true })
        })
        throw new RuntimeError('unreachable')
      }
    })
    await ctx.plugin(BasicCompaction, { auto: true, maxTokens: start.outputTokens, headroomTokens: Math.min(65536, Math.floor((start.contextTokens - start.outputTokens) / 4)) })
    await ctx.plugin(AgentLoop, { agents: [], maxParallelToolCalls: 1 })
    handle = await ctx.agents.create({
      sessionId,
      ...(events.length ? { seed: clone(events) } : {}),
      agentOptions: { provider: 'tandem', model: 'selected', maxTokens: start.outputTokens },
      setup(agentCtx) {
        agentCtx.systemPrompt.section({ name: 'tandem', order: 0, text: start.systemPrompt, interpolate: false, complete: true })
        for (const schema of start.tools) {
          agentCtx.tools.register({
            ...schema,
            output: { schema: {}, render: (_args, value) => [{ type: 'text', text: JSON.stringify(value) }] },
            async execute() { throw new RuntimeError('host_execution_required') }
          })
        }
      }
    })
    agent = handle.agent
    events = capture.stateOf(agent.session)
    signal.addEventListener('abort', abort, { once: true })
    signal.throwIfAborted()
    if (start.snapshot) {
      const pending = start.snapshot.pending
      for (const [index, call] of pending.calls.entries()) {
        const result = start.toolResults[index]
        const recorded = events[call.seq]
        requireValue(recorded?.type === 'tool/call' && recorded.data.callId === call.id && recorded.data.name === call.name && recorded.data.arguments === call.arguments, 'invalid_snapshot')
        agent.session.append('tool/result', {
          ...pending.log,
          message: createToolResultMessage({ callId: call.id, content: [{ type: 'text', text: result.content }], isError: result.isError ?? false })
        }, { surfaceOp: 'append', sourceEventSeqs: [call.seq] })
      }
      events = capture.stateOf(agent.session)
      for (const closer of interruptedTurnClosers(events)) {
        requireValue(closer.type !== 'tool/result', 'result_mismatch')
        agent.session.append(closer.type, closer.data)
      }
    }
    agent.followup(createUserMessage({ source: { kind: 'user' }, content: [{ type: 'text', text: start.snapshot ? 'Continue the assignment using the saved tool results. Do not repeat completed actions.' : start.prompt }] }))
    const outcome = await Promise.race([
      boundary.promise,
      agent.whenIdle().then(() => ({ type: 'idle' }))
    ])
    signal.throwIfAborted()
    if (outcome.type === 'boundary') return outcome
    if (end?.kind === 'max-tokens') throw new RuntimeError('response_cut_short')
    if (end?.kind !== 'completed' || failure) throw new RuntimeError(end?.error?.code ?? failure?.code ?? 'execution_failed')
    const messages = agent.session.deriveMessages()
    const last = messages.findLast(message => message.role === 'assistant')
    const content = last?.content.filter(block => block.type === 'text').map(block => block.text).join('\n') ?? ''
    requireValue(content.trim().length > 0 && !last.content.some(block => block.type === 'tool-call'), 'response_empty')
    events = capture.stateOf(agent.session)
    return { type: 'final', snapshot: snapshot(null), content }
  } finally {
    signal.removeEventListener('abort', abort)
    if (handle) {
      handle.agent.cancel({ kind: 'disposed' })
      await handle.agent.whenIdle()
      await handle.dispose()
    }
    await ctx.fiber.dispose()
  }
}
