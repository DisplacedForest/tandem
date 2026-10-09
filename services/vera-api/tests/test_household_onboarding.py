import pytest

from household_onboarding import SETUP_REQUEST, render


def test_onboarding_requires_a_verified_per_recipient_link():
    pending = render()
    assert 'href="#setup">Start setup' in pending
    assert 'private connection still needs to be prepared' in pending
    assert 'href="https://chatgpt.com/"' in pending
    page = render('https://chatgpt.com/plugins/plugin_synthetic')
    assert 'href="https://chatgpt.com/plugins/plugin_synthetic"' in page
    assert 'does not enroll anyone or verify installation' in page
    for bad in ('http://chatgpt.com/plugins/example', 'https://chatgpt.com.evil/plugins/example', 'https://chatgpt.com/plugins/example?key=secret', 'javascript:alert(1)', 'https://chatgpt.com/plugins/a"onclick="evil'):
        with pytest.raises(ValueError):
            render(bad)


def test_onboarding_requires_user_submission_and_full_event_acceptance():
    page = render()
    assert 'Nothing is sent from this page' in page
    assert 'only when you review and send it' in page
    assert 'Installing the plugin alone does not subscribe your dot' in page
    assert 'native approval' in page
    assert 'No new account is needed' in page
    assert 'gateway has no account signup' in SETUP_REQUEST
    assert 'inbox_setup_check' in SETUP_REQUEST
    assert 'Reuse an existing matching subscription' in SETUP_REQUEST
    assert 'actual event to wake my dot' in SETUP_REQUEST
    assert 'Confirm subscription renewal separately' in SETUP_REQUEST
    for forbidden in ('fetch(', 'XMLHttpRequest', 'localStorage', 'document.cookie', '<form', 'plugin_asdk_app_', 'whsec_'):
        assert forbidden not in page
