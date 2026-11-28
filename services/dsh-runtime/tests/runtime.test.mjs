import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { createInterface } from 'node:readline'
import { advance } from '../runtime.mjs'

const tools = [
  { name: 'read', description: 'Read a host approved file.', parameters: { type: 'object', properties: { path: { type: 'string' } }, required: ['path'], additionalProperties: false } },
  { name: 'write', description: 'Write a host approved file.', parameters: { type: 'object', properties: { path: { type: 'string' }, content: { type: 'string' } }, required: ['path', 'content'], additionalProperties: false } }
]
const start = () => ({ type: 'start', systemPrompt: 'Complete the assignment and verify it.', prompt: 'Fix the project and verify the result.', tools, contextTokens: 131072, outputTokens: 65536 })
const call = (id, name = 'read', args = '{"path":"fixture.txt"}') => ({ id, name, arguments: args })
const calls = (...tool_calls) => ({ type: 'model_result', content: '', tool_calls, finish_reason: 'tool_calls' })
const done = content => ({ type: 'model_result', content, finish_reason: 'stop' })
const receipt = (id, content, isError = false) => ({ role: 'tool', tool_call_id: id, content, isError })
const restore = (base, boundary, toolResults) => ({ ...base, snapshot: boundary.snapshot, toolResults })

async function boundary(base = start(), items = [call('read-1')]) {
  return advance(base, async request => {
    assert.deepEqual(request.tools, base.tools)
    assert.equal(request.toolChoice, 'auto')
    return calls(...items)
  })
}

test('real DSH loop restores verified results through read, correction, write and final verification', async () => {
  const base = start()
  const first = await boundary(base)
  assert.equal(first.type, 'boundary')
  const second = await advance(restore(base, first, [receipt('read-1', 'Failing assertion: expected 2, received 1')]), async request => {
    assert.deepEqual(request.messages.filter(message => message.role === 'tool'), [{ role: 'tool', content: 'Failing assertion: expected 2, received 1', tool_call_id: 'read-1' }])
    return calls(call('write-1', 'write', '{"path":"fixture.txt","content":"2"}'))
  })
  const third = await advance(restore(base, second, [receipt('write-1', 'Saved')]), async request => {
    assert.equal(request.messages.filter(message => message.role === 'tool').length, 2)
    return calls(call('verify-1'))
  })
  const final = await advance(restore(base, third, [receipt('verify-1', 'Checks passed')]), async request => {
    assert.deepEqual(request.messages.filter(message => message.role === 'tool').map(message => message.tool_call_id), ['read-1', 'write-1', 'verify-1'])
    assert.ok(!JSON.stringify(request).includes('TOOL_OUTCOME_UNKNOWN'))
    return done('The correction passed verification.')
  })
  assert.equal(final.type, 'final')
  assert.equal(final.content, 'The correction passed verification.')
  assert.deepEqual(final.snapshot.events.filter(event => event.type === 'tool/result').map(event => event.data.message.toolCallId), ['read-1', 'write-1', 'verify-1'])
})

test('batch checkpoint contains every call in order and only supplied tools are advertised', async () => {
  const first = await boundary(start(), [call('a'), call('b')])
  assert.deepEqual(first.toolCalls.map(item => item.id), ['a', 'b'])
  const final = await advance(restore(start(), first, [receipt('a', 'A'), receipt('b', 'B')]), async request => {
    assert.deepEqual(request.tools, tools)
    assert.deepEqual(request.messages.filter(message => message.role === 'tool').map(message => message.content), ['A', 'B'])
    return done('Both verified.')
  })
  assert.equal(final.type, 'final')
})

test('denied and malformed tool calls return to the model for correction without local execution', async () => {
  const first = await boundary(start(), [call('bad', 'write', '{broken')])
  assert.equal(first.toolCalls[0].arguments, '{broken')
  const next = await advance(restore(start(), first, [receipt('bad', 'Denied: malformed arguments and no write authorization.', true)]), async request => {
    assert.match(request.messages.find(message => message.role === 'tool').content, /Denied/)
    return calls(call('corrected'))
  })
  assert.equal(next.toolCalls[0].name, 'read')
  assert.equal(next.snapshot.events.filter(event => event.type === 'tool/result')[0].data.message.isError, true)
})

test('missing, reordered, duplicate and extra receipts fail before a model request', async () => {
  const first = await boundary(start(), [call('a'), call('b')])
  for (const receipts of [[], [receipt('a', 'A')], [receipt('b', 'B'), receipt('a', 'A')], [receipt('a', 'A'), receipt('a', 'A')], [receipt('a', 'A'), receipt('b', 'B'), receipt('c', 'C')]]) {
    await assert.rejects(advance(restore(start(), first, receipts), async () => assert.fail('must not request model')), { code: 'result_mismatch' })
  }
})

test('changed pending call references are rejected', async () => {
  const first = await boundary()
  first.snapshot.pending.calls[0].arguments = '{"path":"other.txt"}'
  await assert.rejects(advance(restore(start(), first, [receipt('read-1', 'Result')]), async () => assert.fail('must not request model')), { code: 'invalid_snapshot' })
})

test('cutoff and empty answers never become successful final answers', async () => {
  await assert.rejects(advance(start(), async () => ({ ...done('Partial'), finish_reason: 'length' })), { code: 'response_cut_short' })
  await assert.rejects(advance(start(), async () => done('')), { code: 'response_empty' })
})

test('provider failure and malformed duplicate call IDs do not yield executable checkpoints', async () => {
  await assert.rejects(advance(start(), async () => ({ type: 'model_error', code: 'provider_offline' })))
  await assert.rejects(advance(start(), async () => calls(call('a'), call('a'))))
})

test('DSH compaction summarizes old tool results and resumes with preserved host schemas', async () => {
  const base = { ...start(), contextTokens: 8192, outputTokens: 1024 }
  let current = await boundary(base)
  const purposes = []
  for (let index = 0; index < 5; index += 1) {
    const id = current.toolCalls[0].id
    current = await advance(restore(base, current, [receipt(id, `Receipt ${index}: ` + 'verified evidence '.repeat(600))]), async request => {
      purposes.push(request.purpose)
      assert.deepEqual(request.tools, tools)
      if (request.purpose === 'compaction') {
        assert.equal(request.toolChoice, 'none')
        return done('Read results verified. Preserve completed writes and continue the assignment.')
      }
      return index === 4 ? done('Completed after compaction.') : calls(call(`next-${index}`))
    })
  }
  assert.equal(current.type, 'final')
  assert.ok(purposes.includes('compaction'))
  assert.ok(current.snapshot.events.some(event => event.type.startsWith('compaction/')))
  assert.equal(current.snapshot.events.filter(event => event.type === 'tool/result').length, 5)
})

function processRun(onMessage, initial = start()) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [new URL('../sidecar.mjs', import.meta.url).pathname], { stdio: ['pipe', 'pipe', 'pipe'] })
    const messages = []
    let stderr = ''
    const timeout = setTimeout(() => { child.kill('SIGKILL'); reject(new Error('Sidecar did not exit')) }, 10000)
    child.stderr.on('data', data => { stderr += data })
    createInterface({ input: child.stdout }).on('line', line => {
      try {
        const message = JSON.parse(line)
        messages.push(message)
        onMessage(message, value => child.stdin.write(JSON.stringify(value) + '\n'))
      } catch (error) { child.kill('SIGKILL'); reject(error) }
    })
    child.on('error', reject)
    child.on('exit', code => { clearTimeout(timeout); resolve({ code, messages, stderr }) })
    child.stdin.write(JSON.stringify(initial) + '\n')
  })
}

test('NDJSON process completes one host completion and exits cleanly', async () => {
  const result = await processRun((message, send) => {
    if (message.type === 'model') send({ ...done('Process verified.'), id: message.id })
  })
  assert.equal(result.code, 0)
  assert.deepEqual(result.messages.map(message => message.type), ['model', 'final'])
  assert.equal(result.messages[1].content, 'Process verified.')
})

test('NDJSON cancellation interrupts an outstanding model request', async () => {
  const result = await processRun((message, send) => {
    if (message.type === 'model') send({ type: 'cancel' })
  })
  assert.equal(result.code, 1)
  assert.deepEqual(result.messages.map(message => message.type), ['model', 'error'])
  assert.equal(result.messages[1].code, 'canceled')
})

test('NDJSON rejects unknown model response correlation', async () => {
  const result = await processRun((message, send) => {
    if (message.type === 'model') send({ ...done('Wrong response.'), id: 'wrong' })
  })
  assert.equal(result.code, 1)
  assert.equal(result.messages.at(-1).code, 'unexpected_message')
})

test('partial tool calls from an output cutoff never cross the effect boundary', async () => {
  await assert.rejects(advance(start(), async () => ({ ...calls(call('partial')), content: 'Still working', finish_reason: 'length' })), { code: 'response_cut_short' })
})

test('tool boundary preserves useful assistant progress text', async () => {
  const result = await advance(start(), async () => ({ ...calls(call('read-progress')), content: 'Checking the failing assertion.' }))
  assert.equal(result.content, 'Checking the failing assertion.')
})


test('nonalphabetical host tool inventory preserves exact order and nested schemas', async () => {
  const base = { ...start(), tools: [...tools].reverse() }
  await advance(base, async request => {
    assert.deepEqual(request.tools, base.tools)
    return done('Ordered inventory verified.')
  })
})
