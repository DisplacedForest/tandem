import { advance, maximumFrameBytes, RuntimeError } from './runtime.mjs'

const controller = new AbortController()
const pending = new Map()
let started = false
let ended = false
let buffer = Buffer.alloc(0)

function send(value) {
  const line = JSON.stringify(value) + '\n'
  if (Buffer.byteLength(line) > maximumFrameBytes) throw new RuntimeError('frame_too_large')
  process.stdout.write(line)
}

function fail(error) {
  if (ended) return
  ended = true
  controller.abort()
  for (const entry of pending.values()) entry.reject(new RuntimeError('canceled'))
  pending.clear()
  try { send({ type: 'error', code: error instanceof RuntimeError ? error.code : 'runtime_failed' }) } catch {}
  process.exitCode = 1
  process.stdin.destroy()
}

function model(request, signal) {
  return new Promise((resolve, reject) => {
    const stop = () => {
      pending.delete(request.id)
      reject(new RuntimeError('canceled'))
    }
    if (signal?.aborted || controller.signal.aborted) return stop()
    pending.set(request.id, {
      resolve(value) {
        signal?.removeEventListener('abort', stop)
        resolve(value)
      },
      reject(error) {
        signal?.removeEventListener('abort', stop)
        reject(error)
      }
    })
    signal?.addEventListener('abort', stop, { once: true })
    try { send(request) } catch (error) { pending.delete(request.id); reject(error) }
  })
}

function receive(message) {
  if (ended) return
  if (message?.type === 'cancel') return fail(new RuntimeError('canceled'))
  if (!started) {
    started = true
    void advance(message, model, controller.signal).then(result => {
      if (ended) return
      send(result)
      ended = true
      process.stdin.destroy()
    }).catch(fail)
    return
  }
  if (!['model_result', 'model_error'].includes(message?.type) || typeof message.id !== 'string' || !pending.has(message.id)) {
    throw new RuntimeError('unexpected_message')
  }
  const entry = pending.get(message.id)
  pending.delete(message.id)
  entry.resolve(message)
}

process.stdin.on('data', chunk => {
  try {
    buffer = Buffer.concat([buffer, chunk])
    let index
    while ((index = buffer.indexOf(10)) >= 0) {
      if (index > maximumFrameBytes) throw new RuntimeError('frame_too_large')
      const line = buffer.subarray(0, index).toString('utf8')
      buffer = buffer.subarray(index + 1)
      if (!line.trim()) throw new RuntimeError('invalid_request')
      receive(JSON.parse(line))
    }
    if (buffer.length > maximumFrameBytes) throw new RuntimeError('frame_too_large')
  } catch (error) { fail(error) }
})
process.stdin.on('end', () => { if (!ended) fail(new RuntimeError('input_closed')) })
process.stdin.on('error', () => { if (!ended) fail(new RuntimeError('input_closed')) })
process.on('SIGTERM', () => fail(new RuntimeError('canceled')))
process.on('SIGINT', () => fail(new RuntimeError('canceled')))
