# Tools

This page is for contributors adding a tool to the Mac app. A tool is something the model can ask the app to do during an answer: look something up, write a file, add a reminder. Every tool, built in or added later, is one `NativeToolDefinition` (in `NativeChatTools.swift`, under the Mac app's sources) plus the code that runs it.

The model picks tools from their descriptions. The app does everything else: it decides which tools are offered, checks every call's arguments, applies the person's rules, runs the handler and sends the result back tied to the call that asked for it. Nothing a model writes, and nothing inside a tool result, can widen what a tool is allowed to do.

## What a definition holds

The contract, which is what the model sees or what its calls are checked against:

- `name`: the function name the model calls. 1 to 64 ASCII letters, digits, underscores or hyphens, unique across every tool.
- `description`: what the tool does, written for the model. Say when to use it (start that part with "When to use:"), when not to, what it changes and what it returns. Keep it under 4,096 bytes so every transport can carry it.
- `parameters`: a JSON Schema for the arguments, with an object at the root. Describe every field and say whether a string may be empty (`minLength`).
- `outputSchema`: optional. The shape of a successful result.
- `examples`: optional. Argument objects that must fit `parameters`.

Host policy, which the app enforces and the model never sees:

- `effect`: `.read` or `.write`. Reads never show a card. Writes follow the person's rules.
- `action`: the kind of action a write is, for example `.networkSends`, `.fileEdits`, `.reminders` or `.serviceChanges`. A write without one counts as another change.
- `ruleSubjects`: optional. What a call targets (a recipient, a path, a host), so a saved rule can name it.
- `confirmation`: `.none`, or `.required` when the tool must always ask first even if its kind is set to act. A kind set to leave it to you still wins.
- `timeout`: optional deadline for one call. Without it a chat call gets 20 seconds.
- `resultByteBudget`: how much of a result reaches the model. Longer results are cut and marked as cut.
- `isAvailable`: whether the tool can run right now, for example because macOS access was granted or a URL is set.

Presentation:

- `id`: groups tools under one switch in Settings, Tools.
- `title`: the short label on the activity chip and in Settings.
- `wants`: optional phrase a card uses, as in "wants to add a reminder".

The handler:

- `execute`: an async function that gets the checked arguments as `[String: NativeJSONValue]` and returns a `NativeJSONValue`. Throw `NativeToolError.failed` with a plain sentence when it can't finish; that sentence is what the model receives.

## When a tool is offered

A tool is offered when it is switched on, `isAvailable` says it can run, and the current place allows it. Folder tools only appear in a chat with a shared folder, the companion's own tools only appear in its thread, and a connected service's tools only appear where that service was allowed. That's the whole test. The wording of a request never adds or removes a tool, so a tool can't be unlocked or hidden by phrasing.

Before anything is offered, the registry (`NativeToolRegistry`) checks each definition. It keeps out a tool whose name is invalid or already taken (the first one wins), whose description is blank, whose `parameters` or `outputSchema` uses something the validator can't check, or whose example doesn't fit its own schema. Each one kept out is listed in the registry's `issues`. A file in `tools.d` that fails shows a line in Settings, Tools naming the file and what to change.

## How arguments are checked

Every call is parsed as a JSON object and checked against `parameters` before the handler runs. A call that doesn't fit runs nothing and gets a corrective result back that says what was wrong and where, such as `Missing required field 'packet'` (see [When a call is wrong](#when-a-call-is-wrong)). A `null` for an optional field that doesn't accept null is dropped rather than refused.

The validator supports these keywords: `type`, `properties`, `required`, `additionalProperties`, `items`, `prefixItems`, `enum`, `const`, `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `minLength`, `maxLength`, `minItems`, `maxItems`, `minProperties`, `maxProperties`, `uniqueItems`, `allOf`, `anyOf`, `oneOf`, `not`, `$ref`, `$defs` and `$schema` (the 2020-12 or draft-07 identifier). It ignores the annotations `title`, `description`, `$comment`, `default`, `examples`, `deprecated`, `readOnly` and `writeOnly`. Any other keyword, `pattern` and `format` included, means the tool isn't offered and is reported instead. Put a check like that in the handler.

## When a call is wrong

The shared policy lives in `NativeToolRepair.swift` and both transports use it. When a call can't run, the model gets a JSON object instead of a result. `error` is one plain sentence about what went wrong, and the other fields tell it how to recover. When a field has the wrong value, the sentence names that field's path and what it must be, and for a length or a count it also says how many were sent. Every supported bound is named this way: lengths, item and field counts, minimums and maximums (inclusive or exclusive), repeated items, a fixed value, a list of choices and the allowed kinds of value. When an item inside a list is the problem, the item's own path is named, such as `notes[1]`; otherwise the list itself is named. Counts read naturally (`1 item`, `2 items`). A problem with the arguments as a whole reads like `The arguments must have at most 2 fields, and this one has 3`. A missing or undeclared field at the top level keeps the short form shown below; one inside an object or list is named by its full path, such as `Field 'items[1].name' is required`. The result also names the action in plain words from the call's own values, such as `Write the document "Week's plans"`, so the final answer can say what never ran; a tool can supply its own wording by setting `summary` on its definition. For a rule the schema can't express, set `check`: it gets the checked arguments and runs before the handler and before any card is shown, and a sentence it returns is answered like any other invalid call, so it counts toward the same repairs. A handler that throws `NativeToolError.invalidArguments` for bad input is answered and counted the same way, though by then it has run. Each object names a `fault`:

- `malformed_arguments`: the arguments aren't valid JSON, for example a call cut off mid-stream.
- `unknown_tool`: the name isn't one of the tools offered for this request. `offered` lists the names it can use.
- `invalid_arguments`: the arguments are JSON but don't fit `parameters`. `problems` lists up to four, each with `at` (a path such as `filters.shelf` or `items[1].name`) and `expected`.
- `unsupported_value`: the arguments hold something the app can't check or carry, such as arguments too large to check (more than about 32,000 values in one call), or they were refused outright by a connected service's own check, for example a name repeated in one object or arguments over 16 KB.
- `invalid_result`: the handler ran but returned `null`, blank text, or a result that doesn't fit the tool's declared `outputSchema`.

For a call to `shelf_lookup` (titled "Look up a shelf") that leaves out its required `packet`, the model gets:

```json
{
  "action": "Look up a shelf",
  "error": "The tool arguments are invalid: Missing required field 'packet'",
  "fault": "invalid_arguments",
  "fix": "Nothing ran. Correct the arguments and send this call again.",
  "not_run": true,
  "problems": [{"at": "packet", "expected": "is required"}],
  "repairs_left": 2
}
```

For a call to `create_background_task` whose `title` runs to 231 characters, the sentence names the field, its limit and what was sent:

```json
{
  "action": "Write the document \"Plans for the week, day by day, with everything that has to be bought, booked or...\"",
  "error": "The tool arguments are invalid: Field 'title' must be at most 200 characters, and this one has 231",
  "fault": "invalid_arguments",
  "fix": "Nothing ran. Correct the arguments and send this call again.",
  "not_run": true,
  "problems": [{"at": "title", "expected": "must be at most 200 characters, and this one has 231"}],
  "repairs_left": 2
}
```

Inside a list the path names the item, such as `notes[1]`.

Each tool name gets two repairs, counted per answer in chat and per run in handed-off work (unknown names share one count). The first failure says `repairs_left: 2`, the second `1`. A third failure closes that name: the result has `closed: true`, `repairs_left: 0` and a `fix` saying that nothing was started, saved or sent, telling the model not to send it again and to say plainly what couldn't be done. In chat the rest of that round still runs, then the answer is written without tools. When the answer is written without tools, because a name closed or the round or call limits were reached, and the app refused any call in that turn, the request for that answer is also told that some calls never ran and that their results say which. It doesn't list them, and nothing from a call's arguments or a tool's result goes into that instruction. In handed-off work the run goes to its closing write-up, and the counts are saved with the work so a restart doesn't reset them. The report then ends with a line such as `Not run: Write a file "notes/plan.md".` followed by why: the request couldn't be corrected, or the step isn't available in that work. A name's count resets when a call to it returns from its handler, unless the name is already closed.

Repairs aren't free. Every attempt spends the same rounds and calls as any other call, so the chat limits of four rounds and eight calls still hold.

In chat, a write whose outcome isn't known comes back with `outcome: "uncertain"` and a `fix` telling the model to say it couldn't be confirmed. That covers a write that timed out, one that threw an error the app can't read as a clear no, and one that returned a failure after it had started its change. A write that refused its input with `invalidArguments`, even after it started, or a governed tool that stopped before it started, is a clear no and can be called again. The same tool with the same arguments isn't run again for the rest of that answer; the model gets `not_run: true` instead. Different arguments still run, and a read that fails or times out can always be called again. A call the person declined is treated the same way: sent again unchanged in the same answer, it isn't asked about or run, and the model is told it wasn't approved. A card answer that the app records as not coming from the person, such as a card closed when the answer was stopped, doesn't count as a decline, so the call is asked again.

A result of `null`, blank text, or one that doesn't match a declared `outputSchema` counts as an error, not a success. For a write it means the outcome is uncertain, and handed-off work checks what happened before going on. Set `checksOwnResult` on a definition whose handler already checks its own results, as connected services do.

Repairing a call never retries its handler. The app only tells the model what went wrong; any second attempt is a new call the model chooses to send, checked like the first one. Separately, handed-off work retries a read that failed for a passing reason, such as a dropped connection or a timeout, up to twice with short pauses, and it never retries a write.

## Transports

A tool is described once and the app adapts it for each way a model can call it (`NativeToolAdapter` in `NativeToolAdapters.swift`). Both transports send exactly three things per tool: `name`, `description` and `parameters`. The result schema and examples stay on the app's side.

| Transport | Used for | Limits |
|---|---|---|
| Chat | Answers in a conversation, using the standard `tools` and streamed `tool_calls` fields | The registry rules above. Four tool rounds and eight calls per answer. |
| Handed-off work | Assignments your companion runs on its own and reports back on | At most 64 tools per request, names of 1 to 64 bytes, descriptions of at most 4,096 bytes. |

When a tool doesn't fit a transport, it is withheld from that request and reported, and a call to it is refused as an unknown tool. The rest of the tools are still offered. In both transports each result goes back with the id of the call that asked for it, and arguments reach the handler exactly as the model sent them.

## Connected services

Tools from a connected MCP service go through the same checks as built-in ones. Their descriptions come from the service, so the app labels them as untrusted text from that service. A service's hints can only make a tool stricter: a tool you approved as a read that the service marks as not read-only, or as destructive, is treated as a change, and a read-only hint never turns a change into a read. When a service declares a result shape the validator supports, results are checked against it, and one that doesn't match is refused. When a service reports an error, the model gets the service's own text on one line, cut to 400 characters and labelled as untrusted. See [connected service tools](MCP.md) for setup.

## Tools from a file

You can add an HTTP tool without writing Swift by dropping a JSON file in the `tools.d` folder next to the app's `config.json`. The file format, its fields and how a refused file is reported are in [custom chat tools](SETUP.md#custom-chat-tools).

## Adding a read tool

A read tool needs a definition and a handler, nothing more:

```swift
let shelf = NativeToolDefinition(
    id: "garden-shelves",
    name: "shelf_lookup",
    title: "Look up a shelf",
    description: "Reads which greenhouse shelf holds a seed packet. When to use: the person asks where a packet is kept. When not to use: to move a packet, use move_packet. Effects: read only. Returns shelf, the label of the shelf.",
    parameters: .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "required": .array([.string("packet")]),
        "properties": .object([
            "packet": .object([
                "type": .string("string"),
                "minLength": .number(1),
                "description": .string("The packet name as written on its label."),
            ]),
        ]),
    ]),
    confirmation: .none,
    timeout: .seconds(5),
    effect: .read,
    isAvailable: { true },
    execute: { arguments in
        guard case .string(let packet)? = arguments["packet"] else {
            throw NativeToolError.invalidArguments("A packet is required")
        }
        return .object(["shelf": .string(try await GardenShelves.find(packet))])
    })
```

`GardenShelves.find` stands for your own code. Add the definition to the list in `ChatStore.buildToolRegistry` in `Store.swift`. To declare the result shape or add examples, set them on a copy:

```swift
var described = shelf
described.outputSchema = .object([
    "type": .string("object"),
    "properties": .object(["shelf": .object(["type": .string("string")])]),
])
described.examples = [["packet": .string("Runner beans")]]
```

## Adding a write tool

A write tool adds its policy. The app wraps every write in the person's rules for its kind, so the handler doesn't check them itself:

```swift
let label = NativeToolDefinition(
    id: "garden-labels",
    name: "label_shelf",
    title: "Label a shelf",
    description: "Prints a label for a greenhouse shelf. When to use: the person asks for a shelf to be labelled. Effects: sends one print request. Returns printed, true once the label is sent.",
    parameters: .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "required": .array([.string("label")]),
        "properties": .object([
            "label": .object([
                "type": .string("string"),
                "minLength": .number(1),
                "description": .string("The text to print."),
            ]),
        ]),
    ]),
    confirmation: .none,
    effect: .write,
    action: .networkSends,
    isAvailable: { true },
    execute: { arguments in
        guard case .string(let text)? = arguments["label"] else {
            throw NativeToolError.invalidArguments("A label is required")
        }
        try await GardenPrinter.print(text)
        return .object(["printed": .bool(true)])
    },
    wants: "print a shelf label")
```

With sending set to ask first, the call shows a card and the handler waits until the person allows it. Set to leave it to you, the handler never runs and the model is told why. Set to act, it runs straight away.

## Testing a tool

The app's `--selftest` drives tools through the real chat loop with a scripted model. `NativeToolExtensionSelftest.swift` is a working pattern: it adds a read and a write fixture, checks they are offered, called, validated and answered by call id, and checks the rules for the write. Build with `swift build` in `apps/vera-mac` and run the debug app with `--selftest`.

When you add a tool, add cases for it to `apps/vera-mac/Sources/Vera/NativeToolEvalCases.swift`: a few requests that should call it, with the argument checks that prove it got the right target, at least one request that must leave it alone, and a scripted reply for each so `mise run native-tool-eval-test` runs them without a model. If it needs a group of its own, add one to `NativeToolEvalGroup` in `NativeToolEval.swift`, and to the live groups in `NativeToolEvalRunner.swift` if it should be measured against a real model too. The cases are made-up requests only, and nothing outside that file may look at what a case says.
