import asyncio

import pytest

from routers import task_document_core as document


@pytest.mark.parametrize('brief,count', [
    ('Write a plan with three bullet points.', 3),
    ('Create a short Markdown document titled Test Document with three bullet points about the water cycle: evaporation, condensation, precipitation.', 3),
    ('Write a note with three bullets about gardening.', 3),
    ('Explain gardening in 1 bullet.', 1),
    ('List the tradeoffs as twenty bullets.', 20),
    ('Use exactly one bullet point.', 1),
    ('Write a checklist with 20 bullet points.', 20),
])
def test_explicit_count(brief, count):
    assert document._requested_bullets(brief) == count


@pytest.mark.parametrize('brief', [
    'Use at least three bullets.', 'Use at most three bullets.',
    'Write with three bullets minimum.', 'Write with about three bullets.',
    "Don't write with three bullets.", "Repeat 'write with three bullets'.",
    'Write with up to three bullets.', 'Write with three bullets per section.',
    'Write each topic with three bullets.', 'Write with three bullets, not an exact limit.',
    'Write with three bullets or with four bullets.', 'Write with 3-5 bullets.',
    'Write with three to five bullets.', 'Example: write with three bullets.',
    'Quote "write with three bullets".', 'Write with zero bullets.', 'Write with three bullets or fewer.', 'Write with three bullets or more.',
    'Write with 21 bullets.', 'A three bullet example.', 'Explain the supplied material.',
])
def test_ambiguous_or_unsupported_brief_uses_existing_worker(brief):
    assert document._requested_bullets(brief) is None


@pytest.mark.parametrize('text', [
    '- First\n- Second', '- First\n- Second\n- Third\n- Fourth',
    '# Title\n- First\n- Second\n- Third',
    'Introduction\n- First\n- Second\n- Third',
    '```\n- First\n- Second\n- Third\n```',
    '- First\n  - Second\n- Third', '- First\n- \n- Third',
    '1. First\n2. Second\n3. Third', '- ```\n- Second\n- Third',
    '* * *\n* * *\n* * *', '- - First\n- Second\n- Third',
    '- # Heading\n- Second\n- Third', '- > Quote\n- Second\n- Third', '- ***\n- Second\n- Third', '- ##\n- Second\n- Third',
])
def test_invalid_bodies_are_not_silently_reformatted(text):
    assert not document._valid_bullets(text, 3)


def test_counted_list_generation_resume_validation_and_assembly():
    async def run():
        task = {'id': 'list', 'generation': 1, 'payload': {
            'title': 'A checklist', 'brief': 'Write a checklist with three bullet points.'}, 'checkpoint': {}}
        calls = []
        replies = iter([{'text': '- First\n- Second\n- Third'},
                        {'text': '- Repeated\n- Extra'},
                        {'text': '- First revised\n- Second revised\n- Third revised'}])

        async def generate(payload, checkpoint):
            calls.append(checkpoint.phase)
            messages = document._messages(payload, checkpoint)
            assert 'exactly 3 nonempty Markdown bullet lines' in messages[0]['content']
            return next(replies)

        async def advance():
            result = await document.step(task, generate)
            task['checkpoint'] = result.checkpoint
            task['generation'] += 1
            task.pop('decision_reply', None)
            return result

        planned = await advance()
        assert planned.checkpoint['bullet_count'] == 3
        assert len(planned.checkpoint['outline']) == 1
        assert calls == []
        await advance()
        drafted = await advance()
        assert calls == ['draft']
        assert drafted.checkpoint['drafts'] == ['- First\n- Second\n- Third']
        reopened = document.Checkpoint.model_validate(drafted.checkpoint).model_dump()
        task['checkpoint'] = reopened
        await advance()
        invalid = await advance()
        assert invalid.state == 'needs_decision'
        assert 'bullet count' in invalid.decision['prompt']
        assert invalid.checkpoint['drafts'] == drafted.checkpoint['drafts']
        assert invalid.checkpoint['revisions'] == []
        again = await advance()
        assert again.state == 'needs_decision' and calls == ['draft', 'revise']
        task['decision_reply'] = {'action': 'retry'}
        await advance()
        revised = await advance()
        assert revised.checkpoint['phase'] == 'assemble'
        complete = await advance()
        assert complete.state == 'completed'
        assert complete.result['markdown'] == '# A checklist\n\n- First revised\n- Second revised\n- Third revised\n'
        assert calls == ['draft', 'revise', 'revise']
    asyncio.run(run())


def test_assembly_revalidates_and_preserves_draft():
    async def forbidden(*args):
        raise AssertionError('Assembly cannot call a model')
    task = {'id': 'bad', 'generation': 4, 'payload': {'title': 'List', 'brief': 'Write with three bullets.'},
            'checkpoint': {'phase': 'assemble', 'bullet_count': 3,
                           'outline': [{'heading': 'List', 'instructions': 'Write list'}],
                           'drafts': ['- One\n- Two\n- Three'], 'revisions': ['- One\n- Two']}}
    result = asyncio.run(document.step(task, forbidden))
    assert result.state == 'needs_decision'
    assert result.checkpoint['drafts'] == task['checkpoint']['drafts']
    assert result.checkpoint['phase'] == 'revise'


def test_legacy_multisection_checkpoint_is_not_replanned():
    async def forbidden(*args):
        raise AssertionError('Assembly cannot call a model')
    task = {'id': 'legacy', 'generation': 8, 'payload': {'title': 'Legacy', 'brief': 'Write with three bullets.'},
            'checkpoint': {'phase': 'assemble', 'outline': [
                {'heading': 'First', 'instructions': 'First scope'}, {'heading': 'Second', 'instructions': 'Second scope'}],
                'drafts': ['Saved first', 'Saved second'], 'revisions': ['First body', 'Second body']}}
    result = asyncio.run(document.step(task, forbidden))
    assert result.state == 'completed'
    assert result.result['markdown'] == '# Legacy\n\n## First\n\nFirst body\n\n## Second\n\nSecond body\n'


def test_invalid_initial_list_draft_keeps_request_and_waits():
    async def generate(*args):
        return {'text': '- One\n- Two'}
    task = {'id': 'initial', 'generation': 3, 'payload': {'title': 'List', 'brief': 'Write with three bullets.'},
            'checkpoint': {'phase': 'draft', 'bullet_count': 3, 'expected_generation': 3,
                           'outline': [{'heading': 'List', 'instructions': 'Write list'}]}}
    result = asyncio.run(document.step(task, generate))
    assert result.state == 'needs_decision'
    assert result.checkpoint['drafts'] == []
    assert 'draft is saved' not in result.decision['prompt']
    assert result.checkpoint['retry']


@pytest.mark.parametrize('count', [1, 20])
def test_valid_inline_bullets_at_boundaries(count):
    body = '\n'.join('- **Item ' + str(index) + '**: A useful fact.' for index in range(count))
    assert document._valid_bullets(body, count)
