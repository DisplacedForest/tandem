import html
import re
import subprocess
import sys
from pathlib import Path

import pytest

from household_onboarding import SETUP_REQUEST, render, setup_request


APP_ID = 'asdk_app_' + '1' * 32
PLUGIN_URL = 'https://chatgpt.com/plugins/plugin_' + APP_ID


def test_missing_destination_has_no_actionable_request():
    page = render()
    assert 'Setup is not available yet.' in page
    assert 'Your personal link comes first' in page
    for absent in ('Start setup', 'Copy setup request', '<textarea', '<script', 'href="https://chatgpt.com/"', 'plugin_asdk_app_'):
        assert absent not in page


def test_request_carries_exact_destination_and_subscription_source():
    page = render(PLUGIN_URL, APP_ID)
    assert f'href="{PLUGIN_URL}"' in page
    copied = html.unescape(re.search(r'<textarea[^>]*>(.*?)</textarea>', page, re.S).group(1))
    assert copied == setup_request(PLUGIN_URL, APP_ID)
    assert PLUGIN_URL in copied
    assert APP_ID in copied
    assert 'household-inbox-setup skill' in copied
    assert 'Use only my assigned connection' in copied
    assert 'stop and explain what is missing' in copied
    assert len(copied) < 650


@pytest.mark.parametrize('url,app_id', [
    (PLUGIN_URL, None),
    (None, APP_ID),
    (PLUGIN_URL, 'asdk_app_' + '2' * 32),
    ('http://chatgpt.com/plugins/plugin_' + APP_ID, APP_ID),
    (PLUGIN_URL + '?key=secret', APP_ID),
    ('https://chatgpt.com.evil/plugins/plugin_' + APP_ID, APP_ID),
    ('javascript:alert(1)', APP_ID),
    (PLUGIN_URL, APP_ID + '"onclick="evil'),
    (PLUGIN_URL, ''),
])
def test_incomplete_or_mismatched_destination_is_rejected(url, app_id):
    with pytest.raises(ValueError):
        render(url, app_id)


def test_onboarding_requires_user_submission_and_full_event_acceptance():
    page = render(PLUGIN_URL, APP_ID)
    assert 'Nothing is sent from this page' in page
    assert 'Review the request before sending' in page
    assert 'Connecting alone does not turn on notifications' in page
    assert 'chat where your dot manages inbox notifications' in page
    assert 'connection or setup skill is unavailable' in SETUP_REQUEST
    assert 'No new account is needed' in page
    assert 'one test message to my own inbox' in SETUP_REQUEST
    assert 'Reuse my matching subscription' in SETUP_REQUEST
    assert 'test actually arrives and is handled' in page
    assert 'Setup does not pair you with anyone' in page
    for forbidden in ('fetch(', 'XMLHttpRequest', 'localStorage', 'document.cookie', '<form', 'whsec_'):
        assert forbidden not in page


def test_cli_passes_destination_and_rejects_incomplete_config_without_output(tmp_path):
    script = Path(__file__).parents[1] / 'household_onboarding.py'
    output = tmp_path / 'index.html'
    command = [sys.executable, str(script), '--plugin-url', PLUGIN_URL, '--output', str(output)]
    assert subprocess.run(command, capture_output=True).returncode != 0
    assert not output.exists()
    assert subprocess.run(command + ['--app-id', APP_ID], capture_output=True).returncode == 0
    assert output.read_text() == render(PLUGIN_URL, APP_ID)
    assert subprocess.run(command + ['--app-id', APP_ID], capture_output=True).returncode != 0
