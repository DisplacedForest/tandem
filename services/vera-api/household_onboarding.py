import argparse
import html
import re
from pathlib import Path


SETUP_REQUEST = """Set up my inbox using this plugin's bundled household-inbox-setup skill. I approve incoming notifications and one test message to my own inbox. Reuse my matching subscription if it already exists. Use only my assigned connection. If the connection or setup skill is unavailable, stop and explain what is missing. Keep my private conversations and memories separate. Pairing and sharing need my separate approval."""


def setup_request(plugin_url: str, app_id: str) -> str:
    if not re.fullmatch(r"asdk_app_[a-f0-9]{32}", app_id):
        raise ValueError("Use the verified registered App ID")
    if plugin_url != f"https://chatgpt.com/plugins/plugin_{app_id}":
        raise ValueError("The verified plugin URL must match the registered App ID")
    return f"My inbox plugin: {plugin_url}\n\n{SETUP_REQUEST}"


def render(plugin_url: str | None = None, app_id: str | None = None) -> str:
    if bool(plugin_url) != bool(app_id):
        raise ValueError("Provide both the verified plugin URL and registered App ID")
    request = setup_request(plugin_url, app_id) if plugin_url and app_id else None
    action = f'<a class="connect" href="{html.escape(plugin_url, quote=True)}" rel="noreferrer">Open my inbox setup <span aria-hidden="true">↗</span></a>' if plugin_url else '<p><strong>Setup is not available yet.</strong></p>'
    availability = 'Review the installation and connection prompts in your own ChatGPT account.' if plugin_url else 'This page has no inbox plugin link assigned to you. Ask the person setting this up for your personal inbox link. They will prepare the connection after you opt in.'
    request_section = '''<section aria-labelledby="request-title"><h2 id="request-title">Let your dot handle setup</h2><p>After connecting, send this request in the chat where your dot manages inbox notifications. Use Work if that is where your dot runs. If ChatGPT offers Run setup, continue with your own dot. Nothing is sent from this page.</p><textarea id="request" aria-label="Setup request to review and send" readonly style="width:100%;min-height:170px;padding:16px;font:15px/1.5 system-ui;border:1px solid #788d77;border-radius:8px">''' + html.escape(request) + '''</textarea><p style="margin-top:16px"><button class="connect" type="button" id="copy-request">Copy setup request</button> <a href="https://chatgpt.com/" rel="noreferrer">Open ChatGPT</a></p><p id="copy-result" role="status" class="note">Review the request before sending. Your dot will check the connection and help you turn on notifications.</p></section>
<script>
document.getElementById('copy-request').addEventListener('click', async function () {
  const field = document.getElementById('request');
  const result = document.getElementById('copy-result');
  try {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(field.value);
    } else {
      field.focus();
      field.select();
      if (!document.execCommand('copy')) throw new Error('Copy unavailable');
    }
    result.textContent = 'Copied. Review and send this request to your dot in ChatGPT.';
  } catch (error) {
    field.focus();
    field.select();
    result.textContent = 'Request selected. Copy it, then review and send it to your dot in ChatGPT.';
  }
});
</script>
''' if request else '<section><h2>Your personal link comes first</h2><p>Each person gets a separate inbox link. Once yours is ready, you can connect and let your dot guide you through setup. You will not need a ZIP file, server address, or new account.</p></section>'
    return '''<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer"><title>Connect your inbox</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#f3f1ea;color:#24372c;font:17px/1.6 system-ui,sans-serif}main{max-width:760px;margin:auto;padding:64px 28px}header{border-bottom:1px solid #ccd2c8;padding-bottom:36px}.mark{width:44px;height:44px;border:1px solid #788d77;border-radius:13px;display:grid;place-items:center;margin-bottom:30px}h1{font:500 clamp(36px,6vw,54px)/1.12 Georgia,serif;letter-spacing:-1px;margin:0 0 22px}h2{font-size:21px;line-height:1.3;margin:0 0 8px}p{margin:0 0 20px;max-width:58ch}.connect{display:inline-flex;gap:30px;align-items:center;background:#274c39;color:white;border:0;border-radius:8px;padding:14px 22px;font:600 16px system-ui;text-decoration:none}.connect:focus-visible{outline:3px solid #a46b26;outline-offset:4px}.connect:disabled{background:#667569;cursor:not-allowed}ol{padding:0;list-style:none;counter-reset:steps}li{counter-increment:steps;display:grid;grid-template-columns:40px 1fr;gap:12px;padding:24px 0;border-bottom:1px solid #d5d8cf}li:before{content:counter(steps);font:500 27px Georgia,serif;color:#6f806e}.note{font-size:14px;color:#566657}.privacy{margin-top:32px;background:#e6eadd;border-radius:12px;padding:24px}.privacy p{margin:0}code{font:inherit;font-weight:600}footer{margin-top:32px;font-size:14px;color:#566657}
</style><main><header><div class="mark" aria-hidden="true"><svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="3" y="5" width="18" height="14" rx="2"/><path d="m3 6 9 7 9-7"/></svg></div>
<h1>A private inbox<br>for your assistant.</h1><p>Share a message or summary when you choose. Each dot has its own local inbox and connection. No new account is needed. Your conversations and memories stay separate.</p>''' + action + '''<p class="note" style="margin-top:14px">''' + availability + '''</p></header>
<ol id="setup"><li><div><h2>Open your personal link</h2><p>Install and connect the inbox in the ChatGPT session where your dot lives. Review the permissions before approving. Use only the link prepared for you.</p></div></li>
<li><div><h2>Say “Set up my inbox”</h2><p>Return to the chat where your dot manages inbox notifications and ask it to set up your inbox. Approve incoming notifications and one test message when asked.</p></div></li>
<li><div><h2>Wait for the test message</h2><p>Your dot will confirm when the test actually arrives and is handled. If setup gets stuck, it will tell you what needs attention. Connecting alone does not turn on notifications.</p></div></li></ol>
<section><h2>Share when you’re ready</h2><p>Ask your dot to pair with another household member. Both people choose whether to connect and what to share. Setup does not pair you with anyone.</p></section>
''' + request_section + '''
<section class="privacy" aria-label="Your choices"><h2>You decide what leaves your inbox.</h2><p>Approve the exact message or summary before sending. Receiving a message does not give anyone access to your private history or permission to act for you. Either person can end a pairing.</p></section>
<footer>Need help? Ask the person who sent your setup link. You can disconnect your inbox or end a pairing anytime.</footer></main></html>'''


def main() -> None:
    parser = argparse.ArgumentParser(description="Render a private, per-recipient inbox setup page")
    parser.add_argument("--plugin-url")
    parser.add_argument("--app-id")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    page = render(args.plugin_url, args.app_id)
    with args.output.open("x") as output:
        output.write(page)


if __name__ == "__main__":
    main()
