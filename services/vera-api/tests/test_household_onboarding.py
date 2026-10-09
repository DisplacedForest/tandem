import pytest

from household_onboarding import render


def test_onboarding_requires_a_verified_per_recipient_link():
    pending = render()
    assert 'disabled>Connection link pending' in pending
    assert 'href=' not in pending
    page = render('https://chatgpt.com/plugins/plugin_synthetic')
    assert 'href="https://chatgpt.com/plugins/plugin_synthetic"' in page
    assert '<script' not in page
    assert 'does not enroll anyone or verify installation' in page
    for bad in ('http://chatgpt.com/plugins/example', 'https://chatgpt.com.evil/plugins/example', 'https://chatgpt.com/plugins/example?key=secret', 'javascript:alert(1)', 'https://chatgpt.com/plugins/a"onclick="evil'):
        with pytest.raises(ValueError):
            render(bad)
