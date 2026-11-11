# Connected service tools

Tandem uses the official Swift MCP client for explicitly configured remote tools. Focused chat and the persistent workspace use the same enabled catalog and host permission checks. Existing built-in tools, memory and task approval remain in place.

No server is configured by default. Connecting a service does not authorize every tool it describes. Before configuring a service, review its maintained implementation, destination, read semantics, authentication requirements and compatibility. A server's read-only annotation is not permission to execute it.

A service's tools stay off until you approve them, and you approve each one either as a read or as a change. Reads are listed in `read_tools` and run without asking. Changes are listed in `act_tools` and follow the Make changes through connected services rule in Settings, Rules, which asks first by default. A tool named in both lists counts as a change, and the two lists together hold at most 64 names. A saved Always allow or Never for a change covers that whole tool. What a service says about its own tools can only make Tandem more careful: an approved read that the service marks as changing things starts asking first like a change, and nothing a service says turns a tool on or makes a change a read. In a chat, these changes are not yet listed in a history of what changed.

Remote HTTPS supports unauthenticated services, temporary preissued Bearer tokens and explicit OAuth sign-in for reviewed, preregistered public clients. Credentials stay in memory. Saved credentials, local subprocess servers, automatic installation, server-initiated actions and MCP Events are not supported. Redirects, cookies and ambient HTTP credentials are refused by the service and token transports.

A reviewed connection can be declared in `native_mcp_servers` in the existing configuration file:

```json
{
  "native_mcp_servers": [{
    "id": "215dccee-72ed-4bcc-9006-1b9e8da308cd",
    "name": "Reference service",
    "url": "https://reference.example/mcp",
    "read_tools": ["lookup_reference"],
    "act_tools": ["add_reference_note"],
    "scopes": ["focused", "assistant"],
    "timeout_seconds": 20
  }]
}
```

This example is not a deployed service. Use the reviewed server's real endpoint and exact approved tool names. `act_tools` is optional; leave it out to approve only reads. Do not put credentials in its URL or this declaration. You can edit the file by hand, or let the Integrations destination write the same list when you install, edit or remove a server. Changes made in the app take effect immediately. Open Integrations, Personal, then Connect. Enable the discovered tool and Save. Connections are not reopened automatically after restart. Disconnect or disable a tool to revoke active access, and Remove under Manage disconnects a server and withdraws its tools from every scope at once. Worker access requires an explicit `worker` scope in addition to the existing task approval.

For a reviewed service that accepts a preissued Bearer token, add `"authentication": "bearer"` to its declaration. In Integrations, Personal, enter that service's token in the secure field and explicitly connect. Use a token issued for that exact service with only its required read permissions. Never reuse a model provider key. Vera keeps the token only in memory for the current connection, for at most one hour. Disconnecting, a rejected credential or an expired connection requires fresh token entry. Reopening Vera does not restore credentials or reconnect. Disconnecting locally does not revoke a token at its issuer.

A server response asking for authentication or broader scopes stops the connection. It never starts sign-in, broadens consent, registers a client or retries the interrupted call automatically.

For OAuth, obtain a preregistered public client identifier from the service and review its exact resource, issuer, metadata destinations, authorization endpoint, token endpoint, callback and required scopes. Configure `"authentication": "oauth"` and an `oauth` object alongside the server declaration:

```json
{
  "resource": "https://reference.example/mcp",
  "issuer": "https://login.reference.example",
  "protected_resource_metadata_url": "https://reference.example/.well-known/oauth-protected-resource/mcp",
  "authorization_server_metadata_url": "https://login.reference.example/.well-known/oauth-authorization-server",
  "authorization_endpoint": "https://login.reference.example/authorize",
  "token_endpoint": "https://login.reference.example/token",
  "client_id": "preregistered-public-client",
  "redirect_uri": "vera-oauth://callback",
  "scopes": ["reference.read"]
}
```

These are examples, not configured services. The resource must exactly match the server URL. No client secret, access token or refresh token belongs in this object. The authorization server must support a public client, S256 PKCE and an issuer-bound authorization response. Its metadata must match the configured destinations and approved scopes.

In Integrations, Personal, choose Review sign-in access. Check the destinations and scopes, then choose Sign in to start the browser session. Successful sign-in connects the service; enable the reviewed read tools and Save. Closing an unfinished sign-in cancels that attempt. Leaving Integrations after a successful connection leaves the approved tools available.

Refresh sign-in explicitly rotates authorization within the original approved scopes and one-hour maximum session lifetime. It does not extend that lifetime, start another grant or replay a tool call. Disconnect, authorization failure, expiry and quitting Vera discard the session locally. Reopening requires a new review and sign-in. Local disconnection does not revoke a grant at its issuer. This deliberately restricted workflow does not claim full MCP OAuth conformance.

In Integrations, Personal, Try verifies an enabled read tool without using a model connection. Changes, and approved reads that now ask first, can't be tried. Enter the page URL for a simple documentation tool, or the required arguments for another read tool. Tandem validates the input through the same authority used by chat and shows a bounded result with its source. Cancel or close the test to stop it. A canceled or failed connection may need to be connected again. Trying a tool never enables a tool or starts sign-in automatically.

Tool identities include the configured server identity, destination and remote name. Moving a server does not inherit the old destination's enabled tools. Discovery preserves complete argument schemas. Tool argument schemas require an explicit object root. Nested arrays and boolean schemas remain supported. The validator accepts its supported 2020-12 constructs and a common draft-07 subset. Draft-07 references, definitions, tuple arrays and conditional keywords remain unavailable; declaring a dialect does not bypass those checks. Unsupported schemas remain visible but unavailable; the inspector shows the original schema. Supported schema constructs are documented in the source validator and covered by its fixtures. There is no schema flattening to the generic HTTP tool format. JSON numbers that cannot round-trip through the native numeric representation are refused before decoding, including integers beyond the exact safe range and excessive decimal precision. The SDK decodes some data-URL strings as binary values; those schemas and structured results are refused rather than silently rewritten.

Discovery is bounded to eight pages and 128 tools, each with a 32 KiB schema. Calls validate arguments before network dispatch, recheck current enablement and scope, and have a configured timeout of at most 20 seconds. Results exposed to the model are bounded to 4 KiB including source attribution. Narrow the query if a service returns too much data. A failed or canceled connection requires explicit reconnection; calls are never automatically replayed. Cancellation stops waiting and cancels the transport but cannot guarantee a remote server stopped work.

The persistent workspace offers only approved reads, never changes. It accepts at most 16 enabled tools, 8 KiB of total catalog JSON and 2 KiB per description, with object-root schemas. A catalog beyond those bounds is refused in that workspace; disable unused tools or use a narrower service catalog. A task whose MCP authorization became stale after disconnect or a permission change stays refused on retry. Start a new explicitly approved task after reconnecting.

Only tools you approved are exposed. A change runs only as the Make changes through connected services rule allows, with the same cards and refusals as other changes, and is never sent twice on its own. Changing a provider or execution path does not authorize a different tool, create a memory store, or replace the Python task authority.

## Starter list

Integrations, Public is a bundled list of well-known remote HTTP MCP servers, shipped as a JSON resource in the app. It has search and categories. Install opens a review of the endpoint, the proposed read tools (each can be left off) and the scopes, then creates the personal entry and continues with the usual connect or sign-in step. An installed entry shows Installed. Manage lists the entry's name, endpoint, approved reads and changes, scopes, authentication and timeout, with Remove.

The first list:

- DeepWiki (Cognition)
- Context7 (Upstash)
- Microsoft Learn (Microsoft)
- Cloudflare Docs (Cloudflare)
- Astro Docs (Astro)
- Semgrep (Semgrep)
- Globalping (jsDelivr)
- GitHub (GitHub), access token
- Sentry (Sentry), access token
- Hugging Face (Hugging Face), access token

Entries are remote HTTP servers only and record the publisher and the publisher's page. Tool names are the publishers' current names and are reviewed before Install. If a publisher renames a tool, the old name stops working and the new one shows as Not approved on the service's page until you correct it under Manage. Listing a publisher is not a verification of the service. The list does not supply OAuth client details, so an OAuth entry still needs the publisher's preregistered public client in its configuration as described above.

A row written from the starter list may carry two optional keys, `publisher` and `source_url`. They are informational and a hand-written declaration can omit them. The limit of eight servers applies to the list as a whole.

Local stdio servers, a remote registry fetch, plugin packages and publisher verification are not part of this.

Run `mise run native-mcp-test` for schema, shared-authority and synthetic HTTP SDK tests, and `mise run check` for the repository regressions. The HTTP fixture binds only to loopback and makes no paid model calls. Synthetic test results do not establish live-service compatibility. See [SDK evaluation](MCP_SDK.md) for the exact dependency pin and transport boundaries.
