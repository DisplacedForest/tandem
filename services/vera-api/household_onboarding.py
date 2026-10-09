import argparse
import html
import re
from pathlib import Path


def render(plugin_url: str | None = None) -> str:
    if plugin_url and not re.fullmatch(r"https://chatgpt\.com/plugins/[A-Za-z0-9_-]+", plugin_url):
        raise ValueError("Use the verified HTTPS ChatGPT plugin page, without query parameters")
    action = f'<a class="connect" href="{html.escape(plugin_url, quote=True)}" rel="noreferrer">Connect plugin <span aria-hidden="true">↗</span></a>' if plugin_url else '<button class="connect" disabled>Connection link pending</button>'
    return '''<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer"><title>Connect your inbox</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#f3f1ea;color:#24372c;font:17px/1.6 system-ui,sans-serif}main{max-width:760px;margin:auto;padding:64px 28px}header{border-bottom:1px solid #ccd2c8;padding-bottom:36px}.mark{width:44px;height:44px;border:1px solid #788d77;border-radius:13px;display:grid;place-items:center;margin-bottom:30px}h1{font:500 clamp(36px,6vw,54px)/1.12 Georgia,serif;letter-spacing:-1px;margin:0 0 22px}h2{font-size:21px;line-height:1.3;margin:0 0 8px}p{margin:0 0 20px;max-width:58ch}.connect{display:inline-flex;gap:30px;align-items:center;background:#274c39;color:white;border:0;border-radius:8px;padding:14px 22px;font:600 16px system-ui;text-decoration:none}.connect:focus-visible{outline:3px solid #a46b26;outline-offset:4px}.connect:disabled{background:#667569;cursor:not-allowed}ol{padding:0;list-style:none;counter-reset:steps}li{counter-increment:steps;display:grid;grid-template-columns:40px 1fr;gap:12px;padding:24px 0;border-bottom:1px solid #d5d8cf}li:before{content:counter(steps);font:500 27px Georgia,serif;color:#6f806e}.note{font-size:14px;color:#566657}.privacy{margin-top:32px;background:#e6eadd;border-radius:12px;padding:24px}.privacy p{margin:0}code{font:inherit;font-weight:600}footer{margin-top:32px;font-size:14px;color:#566657}
</style><main><header><div class="mark" aria-hidden="true"><svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="3" y="5" width="18" height="14" rx="2"/><path d="m3 6 9 7 9-7"/></svg></div>
<h1>A private inbox<br>for your assistant.</h1><p>Share a message or summary when you choose. Your conversations and memories stay separate.</p>''' + action + '''<p class="note" style="margin-top:14px">Opens your assigned plugin in ChatGPT. Use only the connection prepared for you.</p></header>
<ol><li><div><h2>Install and connect</h2><p>Review the plugin in ChatGPT and follow the installation and connection prompts. You can disconnect it anytime in plugin settings.</p></div></li>
<li><div><h2>Check your inbox</h2><p>Ask your assistant: <code>Check my Household inbox.</code> A successful inbox read confirms the connection. Event wake-ups need a separate test.</p></div></li>
<li><div><h2>Choose who you share with</h2><p>Ask to pair with another consenting household member. Review their identity and choose messages, summaries, or both. Sharing begins only after both people agree.</p></div></li></ol>
<section class="privacy" aria-label="Your choices"><h2>You decide what leaves your inbox.</h2><p>Approve the exact message or summary before sending. Incoming messages cannot authorize actions, automatic replies, or access to your private history. Either person can end a pairing.</p></section>
<footer>This page provides setup guidance. It does not enroll anyone or verify installation. Ask the operator for help if your assigned link is missing or opens someone else's inbox.</footer></main></html>'''


def main() -> None:
    parser = argparse.ArgumentParser(description="Render a private, per-recipient inbox setup page")
    parser.add_argument("--plugin-url")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    page = render(args.plugin_url)
    with args.output.open("x") as output:
        output.write(page)


if __name__ == "__main__":
    main()
