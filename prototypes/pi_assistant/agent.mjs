import { createInterface } from 'node:readline';
import { Agent } from '@earendil-works/pi-agent-core';
import { EventStream, Type } from '@earendil-works/pi-ai';

const lines = createInterface({ input: process.stdin });
const pending = new Map();
let agent;
let started = false;
const emit = value => process.stdout.write(JSON.stringify(value) + '\n');
const fail = () => { emit({ type: 'failure', reason: 'adapter_error' }); process.exitCode = 1; lines.close(); };
lines.on('close', () => {
  agent?.abort();
  for (const item of pending.values()) item.reject(new Error('host_closed'));
  setTimeout(() => { try { process.kill(-process.pid, 'SIGKILL'); } catch {} process.exit(0); }, 50);
});
function hostCall(type, value) {
  const id = crypto.randomUUID();
  return new Promise((resolve, reject) => { pending.set(id, { resolve, reject }); emit({ type, id, ...value }); });
}
const zeroUsage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
function message(content, usage = zeroUsage) {
  return { role: 'assistant', content, api: 'vera-transport', provider: 'vera', model: 'explicit-transport', usage, stopReason: content.some(x => x.type === 'toolCall') ? 'toolUse' : 'stop', timestamp: Date.now() };
}
function call(name, args) { return { type: 'toolCall', id: crypto.randomUUID(), name, arguments: args }; }
async function run(config) {
  let rounds = 0;
  let calls = 0;
  const builtins = (config.role === 'worker' ? [
    ['read_file', Type.Object({ path: Type.String() })],
    ['write_file', Type.Object({ path: Type.String(), content: Type.String() })],
    ['check_python', Type.Object({ path: Type.String() })],
  ] : config.mode === 'assistant' ? [['delegate', Type.Object({ objective: Type.String({ minLength: 1, maxLength: 8000 }) })]] : []).map(([name, parameters]) => ({
    name, label: name, description: name === 'delegate' ? 'Accept explicitly requested background work. Returns immediately with a durable task identity. Execution waits for approval.' : 'Operate only on files granted for this task.', parameters,
    execute: async (call_id, args) => {
      if (++calls > 8) throw new Error('tool_limit');
      const result = await hostCall('tool', { call_id, name, args });
      return { content: [{ type: 'text', text: JSON.stringify(result) }], details: {} };
    },
  }));
  const schemas = config.host_tools ?? [];
  if (!Array.isArray(schemas) || schemas.length > 16 || Buffer.byteLength(JSON.stringify(schemas)) > 8192) throw new Error('catalog_limit');
  const names = new Set(builtins.map(tool => tool.name));
  const tools = [...builtins, ...schemas.map(schema => {
    if (!schema || typeof schema.name !== 'string' || schema.name.length !== 44 || !/^mcp_[a-f0-9]{40}$/.test(schema.name) || names.has(schema.name) || typeof schema.description !== 'string' || !schema.parameters || schema.parameters.type !== 'object') throw new Error('catalog_invalid');
    names.add(schema.name);
    return {
      name: schema.name, label: schema.name, description: schema.description, parameters: schema.parameters,
      execute: async (call_id, args) => {
        if (++calls > 8) throw new Error('tool_limit');
        const result = await hostCall('tool', { call_id, name: schema.name, args });
        const text = JSON.stringify(result);
        if (Buffer.byteLength(text) > 8192) throw new Error('result_limit');
        return { content: [{ type: 'text', text }], details: {} };
      },
    };
  })];
  const streamFn = (_model, context) => {
    const stream = new EventStream(x => x.type === 'done' || x.type === 'error', x => x.message ?? x.error);
    Promise.resolve().then(async () => {
      if (++rounds > 4) throw new Error('round_limit');
      let content;
      let usage = zeroUsage;
      if (config.transport !== 'mock') {
        const reply = await hostCall('model', { context });
        content = reply.content;
        if (reply.usage) usage = { ...zeroUsage, input: reply.usage.input, output: reply.usage.output, totalTokens: reply.usage.input + reply.usage.output, cost: { ...zeroUsage.cost, total: reply.usage.cost_usd } };
      } else if (config.role === 'worker' && context.messages.at(-1)?.role === 'toolResult' && context.messages.at(-1)?.isError) {
        content = [{ type: 'text', text: 'Mock coding fixture stopped because a required tool failed.' }];
      } else if (config.role === 'worker') {
        await new Promise(resolve => setTimeout(resolve, config.delay_ms ?? 0));
        const sequence = [call('read_file', { path: 'sum.py' }), call('write_file', { path: 'sum.py', content: 'def add(a, b):\n    return a + b\n' }), call('check_python', { path: 'sum.py' })];
        content = rounds <= sequence.length ? [sequence[rounds - 1]] : [{ type: 'text', text: 'Mock coding fixture updated sum.py and passed syntax validation.' }];
      } else if (config.mode === 'assistant' && config.text.startsWith('/task ') && rounds === 1) {
        content = [call('delegate', { objective: config.text.slice(6) })];
      } else {
        content = [{ type: 'text', text: rounds > 1 ? 'Your task is accepted and awaits approval. I am available for another message.' : `Mock reply: ${config.text}` }];
      }
      const answer = message(content, usage);
      stream.push({ type: 'done', reason: answer.stopReason, message: answer });
      stream.end();
    }).catch(() => {
      const answer = { ...message([]), stopReason: 'error', errorMessage: 'transport_failed' };
      stream.push({ type: 'error', reason: 'error', error: answer }); stream.end();
    });
    return stream;
  };
  agent = new Agent({ initialState: { systemPrompt: config.system_prompt, messages: config.history ?? [], tools }, streamFn, toolExecution: 'sequential', sessionId: config.session_id });
  await agent.prompt(config.text);
  const last = agent.state.messages.filter(x => x.role === 'assistant').at(-1);
  if (!last || ['error', 'aborted'].includes(last.stopReason)) throw new Error('generation_failed');
  emit({ type: 'result', text: last.content.filter(x => x.type === 'text').map(x => x.text).join(''), rounds, calls });
  lines.close();
}
lines.on('line', line => {
  try {
    if (Buffer.byteLength(line) > 262144) throw new Error('line_limit');
    const value = JSON.parse(line);
    if (!started) { started = true; run(value).catch(fail); }
    else if (pending.has(value.id)) {
      const item = pending.get(value.id); pending.delete(value.id);
      if (value.error) item.reject(new Error('host_rejected')); else item.resolve(value.result);
    } else throw new Error('unknown_response');
  } catch { fail(); }
});
