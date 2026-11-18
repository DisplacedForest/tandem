import Foundation

struct NativeToolEvalScript: Sendable {
    let rounds: [[NativeChatStreamSnapshot]]
    var claimed: Bool? = false
    var expected: NativeToolEvalCategory = .pass
    var blockers: Set<NativeToolEvalBlocker> = []
}

enum NativeToolEvalCases {
    static let knownNames: Set<String> = Set(NativeRemindersTools.definitions(service: SelfTestRemindersService()).map(\.name))
        .union(NativeFolderTools.toolNames)
        .union([NativeTaskTools.toolName, NativeWebTools.searchToolName, NativeWebTools.fetchToolName])

    static let seedLines = ["Runner beans", "Sugar snap peas", "Rainbow chard"]
    static let writeLines = seedLines.joined(separator: ", ")
    static let writeContent = "Runner beans\nSugar snap peas\nRainbow chard\n"
    static let saveSeeds = "Save a file named seeds.txt in the shared folder with these three lines: " + writeLines + "."
    static let seededContent = "Runner beans: sow in May\nSugar snap peas: sow in March\n"

    static let weeklyInputs = [
        "Monday is the community garden work morning, from eight until eleven. I want to finish weeding the two raised beds by the gate before the other volunteers start on the compost bays, so bring the long-handled hoe, the kneeling pad and the spare gloves from the shed. If it rains, the session moves to Wednesday at the same time, and the seedlings in the cold frame still need their lids opened by nine. Leave the wheelbarrow by the gate afterwards, because the Thursday group needs it first.",
        "Tuesday evening the branch library holds its book swap from six to eight. I'm bringing two boxes of paperbacks, mostly mysteries and a few travel guides, and they need a quick check for loose pages and pencil notes before they go on the swap table. The volunteer desk asked for a sign listing the house rules, so print the one with the three in, three out limit and the reminder that picture books go on the low shelf. Anything left over at the end goes back in one box for the charity shop.",
        "Wednesday is for sorting the seed packets that arrived last week. They should be grouped by planting month, with anything older than two seasons set aside for a germination test on damp paper towels. Write the sowing depth and the days to sprout on the front of each envelope, and note which varieties came from the seed library so they can be returned with saved seed in the autumn. The empty tin with the blue lid is for packets that are nearly finished.",
        "Thursday afternoon starts the packing for my sister's move to the flat across town. The kitchen goes first: plates wrapped in newspaper, glasses in the divided boxes, and the pantry sorted so nothing open gets packed. Label every box on two sides with the room it goes to and a short list of what is inside, and keep one box with the kettle, mugs, tea and a towel aside for the first night. The van is booked for nine on Saturday, so the boxes need to be stacked by the door on Friday evening.",
        "Friday is for the bookshelves in the hallway, which have been sagging in the middle. Take every book off the top two shelves, add the extra brackets that are in the drawer under the stairs, and put the heaviest hardbacks on the lowest shelf. While the shelves are empty, dust the backs of the books and pull out anything we agreed to give to the library sale, which stops taking donations the following Tuesday. Put the paperbacks that are staying back in alphabetical order by author.",
        "Saturday morning the seedling sale at the farmers market runs from nine to one. We are sharing a table with the allotment society, so bring forty labelled tomato plants, twenty pots of basil and the cash tin with small change. The tablecloth, the price cards and the folding stand are in the green crate, and one of us needs to stay at the table while the other helps unload the van. Whatever does not sell comes home and goes into the cold frame until the next sale.",
        "Sunday is a rest day, but in the evening I want twenty minutes to look back over the week and plan the next one. Note which jobs slipped, what is still waiting on someone else, and anything that needs buying before Monday, such as twine, plant labels and packing tape. Keep the list short enough to fit on one page so it can go on the fridge. If something has slipped two weeks running, move it to the top of the list or let it go.",
    ]

    static var weeklySaid: String {
        "Make me a document of this week's plans that I can keep. Include these seven things:\n"
            + weeklyInputs.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    static let documentChecks: [NativeToolEvalArgumentCheck] = [
        NativeToolEvalArgumentCheck(key: "worker_type", check: .equals("document")),
        NativeToolEvalArgumentCheck(key: "objective", check: .nonEmptyString),
    ]

    static let writeChecks: [NativeToolEvalArgumentCheck] = [
        NativeToolEvalArgumentCheck(key: "path", check: .pathInsideSharedFolder),
        NativeToolEvalArgumentCheck(key: "path", check: .fileNamed("seeds.txt")),
        NativeToolEvalArgumentCheck(key: "content", check: .nonEmptyString),
        NativeToolEvalArgumentCheck(key: "content", check: .containsLines(seedLines)),
    ]

    static func documentCase(_ id: String, _ said: String, heldOut: Bool = false, core: Bool = false, noOutputCap: Bool = false,
                         checks: [NativeToolEvalArgumentCheck] = documentChecks) -> NativeToolEvalCase {
        NativeToolEvalCase(id: id, group: .document, heldOut: heldOut, core: core, walkthrough: core, positive: true, said: said,
                           expectation: NativeToolEvalExpectation(toolName: NativeTaskTools.toolName, argumentChecks: checks,
                                                                  startsWork: true, workKind: .document),
                           noOutputCap: noOutputCap)
    }

    static func answerOnly(_ id: String, _ said: String, group: NativeToolEvalGroup = .document, heldOut: Bool = false,
                           deterministicOnly: Bool = false) -> NativeToolEvalCase {
        NativeToolEvalCase(id: id, group: group, heldOut: heldOut, positive: false, said: said,
                           expectation: NativeToolEvalExpectation(toolName: nil, mustNotRun: [NativeTaskTools.toolName], startsWork: false,
                                                                  mustNotCreateFiles: true, replyMustNotClaim: true),
                           deterministicOnly: deterministicOnly)
    }

    static func folderWrite(_ id: String, group: NativeToolEvalGroup = .folder, core: Bool = false, said: String = saveSeeds,
                            seeded: [String] = [], deterministicOnly: Bool = false) -> NativeToolEvalCase {
        NativeToolEvalCase(id: id, group: group, core: core, walkthrough: core, positive: true, said: said,
                           setup: .sharedFolder(present: true, seeded: seeded), cards: .allow,
                           expectation: NativeToolEvalExpectation(toolName: NativeFolderTools.writeName, argumentChecks: writeChecks,
                                                                  createsFile: "seeds.txt", fileLines: seedLines),
                           deterministicOnly: deterministicOnly)
    }

    static let documentCases: [NativeToolEvalCase] = [
        documentCase("doc-create-reading-list",
                 "Create a document listing ten classic novels for a library reading circle, with a line on why each one suits a group discussion.",
                 core: true),
        documentCase("doc-write-seed-saving",
                 "Write a guide to saving tomato seeds from this year's garden, from picking the fruit to drying and labelling the packets."),
        documentCase("doc-draft-shelf-plan",
                 "Draft a plan for reorganizing the home bookshelves by subject, with a short section for each shelf."),
        documentCase("doc-put-together-moving",
                 "Put together a moving checklist for packing up a small apartment, grouped by the week before, the day before and moving day."),
        documentCase("doc-keep-planting-calendar",
                 "I need a planting calendar for a small vegetable garden that I can keep, month by month from March to October.",
                 heldOut: true),
        documentCase("doc-save-book-swap",
                 "Save a write-up of how our neighborhood library's book swap works, covering drop-off, labelling and how long books stay on the shelf.",
                 heldOut: true),
        documentCase("doc-create-seed-inventory",
                 "Create a seed packet inventory document sorted by planting month, with columns for variety, quantity and the year each packet was bought.",
                 heldOut: true),
        documentCase("weekly-plans-seven-inputs", weeklySaid, core: true,
                 checks: documentChecks + [NativeToolEvalArgumentCheck(key: "deliverables", check: .arrayCountAtLeast(1))]),
        documentCase("document-no-output-cap",
                 "Write a document explaining how to start a compost pile for a community garden, with a short section on what to keep out of it.",
                 core: true, noOutputCap: true),
        documentCase("doc-draft-welcome-letter",
                 "Draft a welcome letter for new members of a library book club and keep it so I can print it later.",
                 heldOut: true),
        documentCase("doc-put-together-hardback-care",
                 "Put together a short guide to caring for old hardback books on open shelves, covering light, dust and humidity."),
        answerOnly("doc-negative-read-only", "Give me three quick names for a garden bench sign, just in your reply."),
        answerOnly("doc-negative-question", "How deep should garlic cloves be planted?", heldOut: true),
        answerOnly("doc-negative-no-saving",
                   "Tell me what to pack first when moving house, but don't write anything down or save anything, just answer here."),
    ]

    static let folderCases: [NativeToolEvalCase] = [
        folderWrite("folder-write-seeds", core: true),
        NativeToolEvalCase(id: "folder-write-declined", group: .folder, positive: false, said: saveSeeds,
                           setup: .sharedFolder(present: true, seeded: []), cards: .decline,
                           expectation: NativeToolEvalExpectation(toolName: nil, mustNotCreateFiles: true, replyMustNotClaim: true)),
        NativeToolEvalCase(id: "folder-list", group: .folder, heldOut: true, positive: true, said: "Which files are in the shared folder?",
                           setup: .sharedFolder(present: true, seeded: ["seeds.txt", "planting-calendar.txt"]),
                           expectation: NativeToolEvalExpectation(toolName: NativeFolderTools.listName,
                                                                  argumentChecks: [NativeToolEvalArgumentCheck(key: "path", check: .pathInsideSharedFolder)],
                                                                  mustNotRun: [NativeFolderTools.writeName], replyMustNotClaim: true)),
        NativeToolEvalCase(id: "folder-write-missing", group: .folder, core: true, walkthrough: true, positive: false, said: saveSeeds,
                           setup: .sharedFolder(present: false, seeded: []), cards: .allow,
                           expectation: NativeToolEvalExpectation(toolName: NativeFolderTools.writeName, argumentChecks: writeChecks,
                                                                  mustNotCreateFiles: true, replyMustNotClaim: true, expectsUnavailable: true)),
        NativeToolEvalCase(id: "folder-write-none", group: .folder, heldOut: true, positive: false,
                           said: "Save a file named seeds.txt with these three lines: " + writeLines + ".",
                           expectation: NativeToolEvalExpectation(toolName: nil, mustNotCreateFiles: true, replyMustNotClaim: true,
                                                                  expectsUnavailable: true)),
    ]

    static let ownerDeliverables: [String] = [
        weeklyInputs[2] + " " + weeklyInputs[6],
        "Water the cold frame seedlings every morning.",
        "Return the borrowed pruning saw on Thursday.",
        "Order two bags of seed compost.",
        "Check the library sale donation deadline.",
        "Print price cards for the seedling sale.",
        "Buy twine and plant labels before Monday.",
    ]

    static let repairCases: [NativeToolEvalCase] = [
        NativeToolEvalCase(id: "repair-corrected", group: .repair, positive: true,
                           said: "Write a planting guide for the north beds that I can keep.",
                           expectation: NativeToolEvalExpectation(toolName: NativeTaskTools.toolName, argumentChecks: documentChecks,
                                                                  startsWork: true),
                           deterministicOnly: true, recovery: true),
        NativeToolEvalCase(id: "repair-three-invalid", group: .repair, positive: true,
                           said: "Write a planting guide for the south beds that I can keep.",
                           expectation: NativeToolEvalExpectation(toolName: NativeTaskTools.toolName, argumentChecks: documentChecks,
                                                                  startsWork: true),
                           deterministicOnly: true, recovery: true),
        NativeToolEvalCase(id: "repair-owner-sequence", group: .repair, positive: true,
                           said: "Put together a document of the week's garden plans with these seven notes: "
                               + ownerDeliverables.joined(separator: " "),
                           expectation: NativeToolEvalExpectation(toolName: NativeTaskTools.toolName,
                                                                  argumentChecks: documentChecks + [NativeToolEvalArgumentCheck(key: "deliverables", check: .arrayCountAtLeast(7))],
                                                                  startsWork: true),
                           deterministicOnly: true, recovery: true),
        NativeToolEvalCase(id: "repair-oversized", group: .repair, positive: true,
                           said: "Make one document out of every plan I have written down this season.",
                           expectation: NativeToolEvalExpectation(toolName: NativeTaskTools.toolName, argumentChecks: documentChecks,
                                                                  startsWork: true),
                           deterministicOnly: true, recovery: true),
    ]

    static let accountingCases: [NativeToolEvalCase] = [
        folderWrite("accounting-wrong-tool", group: .accounting, deterministicOnly: true),
        folderWrite("accounting-wrong-target", group: .accounting, deterministicOnly: true),
        folderWrite("accounting-wrong-target-claimed", group: .accounting, deterministicOnly: true),
        folderWrite("accounting-trash", group: .accounting, seeded: ["planting-calendar.txt"], deterministicOnly: true),
        folderWrite("accounting-extra-write", group: .accounting, deterministicOnly: true),
        folderWrite("accounting-wrong-content", group: .accounting, deterministicOnly: true),
        folderWrite("accounting-cut-short", group: .accounting, deterministicOnly: true),
        NativeToolEvalCase(id: "accounting-false-success", group: .accounting, positive: true,
                           said: "Write a short guide to labelling seed packets and keep it.",
                           expectation: NativeToolEvalExpectation(toolName: NativeTaskTools.toolName, argumentChecks: documentChecks,
                                                                  startsWork: true),
                           deterministicOnly: true),
        folderWrite("accounting-duplicate", group: .accounting, deterministicOnly: true),
        answerOnly("accounting-unauthorized", "How long do seed packets keep? Just tell me here.", group: .accounting, deterministicOnly: true),
        NativeToolEvalCase(id: "accounting-unreadable-claim", group: .accounting, positive: true,
                           said: "Write a short guide to storing seed packets and keep it.",
                           expectation: NativeToolEvalExpectation(toolName: NativeTaskTools.toolName, argumentChecks: documentChecks,
                                                                  startsWork: true),
                           deterministicOnly: true),
        folderWrite("accounting-clean-pass", group: .accounting, deterministicOnly: true),
        NativeToolEvalCase(id: "accounting-declined-claimed", group: .accounting, positive: false, said: saveSeeds,
                           setup: .sharedFolder(present: true, seeded: []), cards: .decline,
                           expectation: NativeToolEvalExpectation(toolName: nil, mustNotCreateFiles: true, replyMustNotClaim: true),
                           deterministicOnly: true),
        answerOnly("accounting-clean-negative", "How many seed packets fit in a shoebox?", group: .accounting, deterministicOnly: true),
    ]

    static let all: [NativeToolEvalCase] = documentCases + folderCases + repairCases + accountingCases

    static func ready(_ groups: Set<NativeToolEvalGroup>, live: Bool) -> [NativeToolEvalCase] {
        all.filter { groups.contains($0.group) && !(live && $0.deterministicOnly) }
    }

    static func encoded(_ object: [String: NativeJSONValue]) -> String {
        (try? NativeToolLoop.serializedResult(.object(object))) ?? "{}"
    }

    static func call(_ id: String, _ name: String, _ arguments: [String: NativeJSONValue]) -> [NativeChatStreamSnapshot] {
        [NativeChatStreamSnapshot(content: "", toolCalls: [NativeChatToolCall(id: id, name: name, arguments: encoded(arguments))],
                                  finishReason: "tool_calls")]
    }

    static func say(_ text: String) -> [NativeChatStreamSnapshot] {
        [NativeChatStreamSnapshot(content: text, toolCalls: [], finishReason: "stop")]
    }

    static func start(_ id: String, objective: String, title: String, deliverables: [String] = [], kind: String = "document") -> [NativeChatStreamSnapshot] {
        var arguments: [String: NativeJSONValue] = ["worker_type": .string(kind), "objective": .string(objective), "title": .string(title)]
        if !deliverables.isEmpty { arguments["deliverables"] = .array(deliverables.map { .string($0) }) }
        return call(id, NativeTaskTools.toolName, arguments)
    }

    static func write(_ id: String, _ folder: String?, name: String = "seeds.txt") -> [NativeChatStreamSnapshot] {
        call(id, NativeFolderTools.writeName, ["path": .string((folder ?? "") + "/" + name), "content": .string(writeContent)])
    }

    static let startedReply = "I'll put that document together for you now."

    static func started(_ id: String, objective: String, title: String, deliverables: [String] = []) -> NativeToolEvalScript {
        NativeToolEvalScript(rounds: [start(id + "-1", objective: objective, title: title, deliverables: deliverables), say(startedReply)])
    }

    static func script(_ id: String, shared: String?) -> NativeToolEvalScript? {
        switch id {
        case "doc-create-reading-list":
            return started(id, objective: "List ten classic novels for a library reading circle with a line on why each suits discussion.", title: "Reading circle novels")
        case "doc-write-seed-saving":
            return started(id, objective: "A guide to saving tomato seeds, from picking the fruit to drying and labelling the packets.", title: "Saving tomato seeds")
        case "doc-draft-shelf-plan":
            return started(id, objective: "A plan for reorganizing the home bookshelves by subject, one short section per shelf.", title: "Bookshelf plan")
        case "doc-put-together-moving":
            return started(id, objective: "A moving checklist for a small apartment grouped by the week before, the day before and moving day.", title: "Moving checklist")
        case "doc-keep-planting-calendar":
            return started(id, objective: "A month by month planting calendar from March to October for a small vegetable garden.", title: "Planting calendar")
        case "doc-save-book-swap":
            return started(id, objective: "How the neighborhood library book swap works: drop-off, labelling and shelf time.", title: "Book swap guide")
        case "doc-create-seed-inventory":
            return started(id, objective: "A seed packet inventory sorted by planting month with variety, quantity and year bought.", title: "Seed inventory")
        case "weekly-plans-seven-inputs":
            return started(id, objective: "A document of this week's plans, one section per day.", title: "This week's plans", deliverables: weeklyInputs)
        case "document-no-output-cap":
            return started(id, objective: "How to start a compost pile for a community garden, with a short section on what to keep out.", title: "Starting a compost pile")
        case "doc-draft-welcome-letter":
            return started(id, objective: "A welcome letter for new members of a library book club, ready to print.", title: "Book club welcome")
        case "doc-put-together-hardback-care":
            return started(id, objective: "A short guide to caring for old hardback books on open shelves: light, dust and humidity.", title: "Hardback care")
        case "doc-negative-read-only":
            return NativeToolEvalScript(rounds: [say("Here are three: Bean Bench, Sunny Seat and Potting Pause.")])
        case "doc-negative-question":
            return NativeToolEvalScript(rounds: [say("Plant each garlic clove about five centimetres deep, pointed end up.")])
        case "doc-negative-no-saving":
            return NativeToolEvalScript(rounds: [say("Pack the things you use least first, such as books, spare linen and decorations.")])
        case "folder-write-seeds", "accounting-clean-pass":
            return NativeToolEvalScript(rounds: [write(id + "-1", shared), say("The three seed lines are saved in seeds.txt.")])
        case "folder-write-declined":
            return NativeToolEvalScript(rounds: [write(id + "-1", shared), say("You chose not to save it, so seeds.txt was left as it was.")])
        case "folder-list":
            return NativeToolEvalScript(rounds: [call(id + "-1", NativeFolderTools.listName, ["path": .string(shared ?? "")]),
                                                 say("The shared folder holds the planting calendar and the seed list.")])
        case "folder-write-missing":
            return NativeToolEvalScript(rounds: [write(id + "-1", shared), say("The shared folder can't be found, so the seed list was not saved.")])
        case "folder-write-none":
            return NativeToolEvalScript(rounds: [say("No folder is shared with this chat, so there is nowhere to save the seed list yet.")])
        case "repair-corrected":
            let objective = "A planting guide for the north beds."
            return NativeToolEvalScript(rounds: [
                call(id + "-1", NativeTaskTools.toolName, ["worker_type": .string("poem"), "objective": .string(objective)]),
                start(id + "-2", objective: objective, title: "North beds planting guide"),
                say("I'll write the north beds planting guide."),
            ])
        case "repair-three-invalid":
            let missing: [String: NativeJSONValue] = ["worker_type": .string("document"), "title": .string("South beds planting guide")]
            return NativeToolEvalScript(rounds: [
                call(id + "-1", NativeTaskTools.toolName, missing),
                call(id + "-2", NativeTaskTools.toolName, missing),
                call(id + "-3", NativeTaskTools.toolName, missing),
                say("I could not get the south beds guide started this time."),
            ], expected: .validation)
        case "repair-owner-sequence":
            return started(id, objective: "A document of the week's garden plans built from the seven notes.", title: "Garden plans this week",
                           deliverables: ownerDeliverables)
        case "repair-oversized":
            let everything = Array(repeating: weeklyInputs.joined(separator: " "), count: 5).joined(separator: " ")
            return NativeToolEvalScript(rounds: [
                start(id + "-1", objective: "One document of every plan written down this season.", title: "Season plans", deliverables: [everything]),
                say("That was more than one document can hold, so nothing was started."),
            ], expected: .validation)
        case "accounting-wrong-tool":
            return NativeToolEvalScript(rounds: [call(id + "-1", NativeFolderTools.listName, ["path": .string(shared ?? "")]),
                                                 say("The folder has no seed list yet, so here are the three lines instead.")],
                                        expected: .selection)
        case "accounting-wrong-target":
            return NativeToolEvalScript(rounds: [write(id + "-1", shared, name: "notes.txt"), say("The seed lines are saved in the notes file.")],
                                        expected: .arguments)
        case "accounting-wrong-target-claimed":
            return NativeToolEvalScript(rounds: [write(id + "-1", shared, name: "notes.txt"), say("Your seed lines went into the notes file.")],
                                        claimed: true, expected: .arguments, blockers: [.falseCompletion])
        case "accounting-trash":
            return NativeToolEvalScript(rounds: [call(id + "-1", NativeFolderTools.trashName, ["path": .string((shared ?? "") + "/planting-calendar.txt")]),
                                                 say("I tidied the old calendar out of the shared folder.")],
                                        expected: .selection)
        case "accounting-extra-write":
            return NativeToolEvalScript(rounds: [write(id + "-1", shared), write(id + "-2", shared, name: "notes.txt"),
                                                 say("The seed list is saved, with a spare copy as well.")],
                                        expected: .pass)
        case "accounting-declined-claimed":
            return NativeToolEvalScript(rounds: [write(id + "-1", shared), say("Your three seed lines are saved in seeds.txt.")],
                                        claimed: true, expected: .pass, blockers: [.falseCompletion])
        case "accounting-wrong-content":
            return NativeToolEvalScript(rounds: [call(id + "-1", NativeFolderTools.writeName, ["path": .string((shared ?? "") + "/seeds.txt"),
                                                                                             "content": .string("Tomatoes\nCourgettes\n")]),
                                                 say("The seed list is saved in seeds.txt with what I had to hand.")],
                                        expected: .arguments)
        case "accounting-cut-short":
            return NativeToolEvalScript(rounds: [[NativeChatStreamSnapshot(content: "The seed list starts with runner beans and then", toolCalls: [],
                                                                           finishReason: "length")]],
                                        expected: .selection)
        case "accounting-unreadable-claim":
            return NativeToolEvalScript(rounds: [say("The seed storage guide is ready in your Library now.")],
                                        claimed: nil, expected: .selection)
        case "accounting-false-success":
            return NativeToolEvalScript(rounds: [say("I've written the seed packet labelling guide and saved it to your Library.")],
                                        claimed: true, expected: .selection, blockers: [.falseCompletion])
        case "accounting-duplicate":
            return NativeToolEvalScript(rounds: [call(id + "-1", NativeFolderTools.writeName, ["path": .string("seeds.txt"), "content": .string(writeContent)]),
                                                 write(id + "-2", shared), say("The seed list is saved, twice over.")],
                                        expected: .pass, blockers: [.duplicateWrite])
        case "accounting-unauthorized":
            return NativeToolEvalScript(rounds: [start(id + "-1", objective: "How long seed packets keep.", title: "Seed packet shelf life"),
                                                 say("I'll write up how long seed packets keep.")],
                                        expected: .selection, blockers: [.unauthorizedEffect])
        case "accounting-clean-negative":
            return NativeToolEvalScript(rounds: [say("A standard shoebox holds roughly two hundred seed packets standing on edge.")])
        default:
            return nil
        }
    }
}
