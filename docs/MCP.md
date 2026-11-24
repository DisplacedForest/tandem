# Connected service tools

Tandem uses the official Swift MCP client for explicitly configured remote tools. Focused chat and the persistent workspace use the same enabled catalog and host permission checks. Existing built-in tools, memory and task approval remain in place.

No server is configured by default. A service with no stored tool list uses every tool the service reports, and the service's own labels decide which are reads. A service with a list offers only what's on it. Before configuring a service, review its maintained implementation, destination, read semantics, authentication requirements and compatibility.

A declaration with neither `read_tools` nor `act_tools` takes every tool the service reports, with the service's own name and description. A tool the service marks read-only is a read and runs without asking. Anything else is a change. All of them are on once the service connects, including tools it adds later, and you can turn any of them off, which is kept in `off_tools`. Here the service's word decides what is a read, so connect only services you trust.

In a declaration with either list, a tool stays off until you approve it, either as a read or as a change. Reads are listed in `read_tools` and run without asking. Changes are listed in `act_tools` and follow the Make changes through connected services rule in Settings, Rules, which asks first by default. A tool named in both lists counts as a change. A saved Always allow or Never for a change covers that whole tool. With a list, what a service says about its own tools can only make Tandem more careful: an approved read that the service marks as not read-only, or as destructive without also marking it read-only, starts asking first like a change, and nothing it says turns a tool on or makes a change a read. In a chat, these changes are not yet listed in a history of what changed.

Tandem accepts MCP protocol versions 2025-11-25, 2025-06-18, 2025-03-26 and 2024-11-05. A server that settles on any other version is refused when connecting.

Tandem supports unauthenticated services, preissued Bearer tokens and explicit OAuth sign-in for reviewed, preregistered public clients. A Bearer token is kept in the macOS keychain. OAuth credentials stay in memory. Local subprocess servers, automatic installation, server-initiated actions and MCP Events are not supported. Redirects, cookies and ambient HTTP credentials are refused by the service and token transports.

A service address must be https, unless it is on your own network and you supplied it yourself. Plain http is accepted for private IPv4 addresses (the RFC 1918 ranges), link-local and unique-local IPv6 addresses, names ending in `.local`, `.lan` or `.home.arpa`, single-word host names and this Mac. The bundled list can carry only https addresses. Plain http isn't encrypted, so anyone on that network could read the traffic, including the token.

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

An address can carry a secret in its path, so Tandem moves the whole address to the macOS keychain the first time it loads the declaration, and leaves only the scheme and host in the file with `"address_saved": true`. An address with nothing after the host, or one used with account sign-in, stays as written. To change an address, use Manage, or write a whole new one in the file. If the keychain can't be read, the service's page says so and Tandem tries again by itself. An older version of Tandem refuses the whole list while a row holds that mark, so no service shows there until this version runs again. Nothing is lost, and nothing is sent to the bare host. If a service quotes its own address in an answer, an error or a tool description, Tandem replaces it with the scheme and host before anything else sees it.

This example is not a deployed service. Use the reviewed server's real endpoint and exact approved tool names. `act_tools` is optional; leave it out to approve only reads. Leave out both lists to use every tool the service reports. An empty list is refused. Tandem adds `asks_tools` itself when a service marks an approved read as changing things, so that read keeps asking first even if the service later stops saying so. Removing the tool from the reads, or moving it to changes, clears it. Do not put credentials in its URL or this declaration. You can edit the file by hand, or let the Integrations destination write the same list when you install, edit or remove a server. Changes made in the app take effect immediately. Open Integrations, Personal, then Connect. Enable the discovered tool and Save. A service with a saved token, or one with no sign-in that you connected, reconnects by itself after a restart or a dropped connection, until you disconnect it. Tandem records the second with `stays_connected` in its declaration. An account sign-in is not reopened automatically. A scheduled companion run first gives each service waiting to reconnect one try, for as long as that service's timeout. Disconnect or disable a tool to revoke active access, and Remove under Manage disconnects a server and withdraws its tools from every scope at once. The `worker` scope covers work your companion does on its own, handed off or scheduled. A service added in the app starts with all three scopes; a row in the file without `scopes` has focused and assistant only.

For a reviewed service that accepts a preissued Bearer token, add `"authentication": "bearer"` to its declaration. In Integrations, Personal, enter that service's token in the secure field and explicitly connect. Use a token issued for that exact service with only its required read permissions. Never reuse a model provider key. Once the service connects, Tandem saves the token in the macOS keychain together with the service's address, and never writes it to the configuration file, chat records or logs. It stays until you choose Disconnect or Remove, change the address or turn off the token sign-in, each of which deletes it. Manage shows that a token is saved and offers Replace and Disconnect. If the service can't be reached, Tandem keeps trying, waiting longer each time, up to five minutes. If the service rejects the token, Tandem stops trying and asks for a new one. Disconnecting locally does not revoke a token at its issuer.

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

Refresh sign-in explicitly rotates authorization within the original approved scopes and one-hour maximum session lifetime. It does not extend that lifetime, start another grant or replay a tool call. Disconnect, authorization failure, expiry and quitting Tandem discard the session locally. Reopening requires a new review and sign-in. Local disconnection does not revoke a grant at its issuer. This deliberately restricted workflow does not claim full MCP OAuth conformance.

In Integrations, Personal, Try verifies an enabled read tool without using a model connection. Changes, and approved reads that now ask first, can't be tried. Enter the page URL for a simple documentation tool, or the required arguments for another read tool. Tandem validates the input through the same authority used by chat and shows a bounded result with its source. Cancel or close the test to stop it. A canceled or failed connection may need to be connected again. Trying a tool never enables a tool or starts sign-in automatically.

Tool identities include the configured server identity, destination and remote name. Moving a server does not inherit the old destination's enabled tools. Discovery preserves complete argument schemas, and keeps each tool's declared title and result schema. Tool argument schemas require an explicit object root. Nested arrays and boolean schemas remain supported. The validator accepts its supported 2020-12 constructs and a common draft-07 subset. Draft-07 references, definitions, tuple arrays and conditional keywords remain unavailable; declaring a dialect does not bypass those checks. Unsupported schemas remain visible but unavailable; the inspector shows the original schema. Supported schema constructs are documented in the source validator and covered by its fixtures. There is no schema flattening to the generic HTTP tool format. In what a service sends, an integer too large to hold exactly is carried as text with every digit kept, and a decimal with many digits is accepted. A result carrying a number as text, or too big to check, is passed on without checking its declared shape. Arguments sent to a tool still refuse both. The SDK decodes some data-URL strings as binary values; those schemas and structured results are refused rather than silently rewritten.

Discovery lists every tool the service offers, as it describes them. A tool with no name, or a name already used, is skipped and the service's page says so. Calls validate arguments before network dispatch, recheck current enablement and scope, and have a configured timeout of at most 20 seconds. One response from a service can be up to 1,048,576 bytes, and a larger one is refused with that number. A long result that fits is shortened for the model like any other tool result and marked as shortened. A result names the service by scheme and host only, never by its full address. When a tool declares a result schema the validator supports, a result's structured content is checked against it, and a result that does not match is refused rather than passed on as if it were valid. A tool whose declared result schema the validator can't check is not offered; Integrations shows it with that reason and its switch off. When a service marks a result as an error, the model receives the service's own error text on one line, cut to 400 characters and labelled as untrusted text from the service. It is data, never instructions. A failed or canceled account sign-in connection requires explicit reconnection; calls are never automatically replayed. Cancellation stops waiting and cancels the transport but cannot guarantee a remote server stopped work.

The persistent workspace offers only reads, never changes. A task whose MCP authorization became stale after disconnect or a permission change stays refused on retry. Start a new explicitly approved task after reconnecting.

A change runs only as the Make changes through connected services rule allows, with the same cards and refusals as other changes, and is never sent twice on its own. Always allowing a tool everywhere is saved only after a confirm that shows the service's own description of it. Changing a provider or execution path does not authorize a different tool, create a memory store, or replace the Python task authority.

## The list in Public

Plugins, Public is a short list the project maintains, shipped in the app as `mcp-starter-catalog.json`. It holds Home Assistant and GitHub. Nothing is fetched, and nothing on it is installed or callable until you install it. An installed service is your own copy: a later version that edits or drops a listing leaves it as it was.

An entry looks like this:

```json
{
  "id": "example",
  "name": "Example",
  "publisher": "Example Project",
  "description": "What it does.",
  "category": "Home",
  "icon": "example.png",
  "url": "{address}",
  "authentication": "bearer",
  "fields": [
    { "id": "address", "label": "Address of your server", "secret": false, "target": "address" },
    { "id": "token", "label": "Access token", "secret": true, "optional": true, "target": "credential" }
  ],
  "source_url": "https://example.com/docs"
}
```

- An entry is only a connector. It names no tools and says nothing about which are reads.
- Each field has a `label`, whether it's `secret`, and a `target`: `address` or `credential`. `placeholder`, `help` and `optional` can be left out. There can be one of each target.
- An `address` value is the whole address, so `url` must be the field's id in braces. It can't be secret or optional. Without one, `url` must be a plain https address.
- A `credential` value is handed to the connection as its token. It must be secret and the entry must use `bearer`. It is never written to the configuration. An optional one left empty connects without signing in.
- `category` is any text and appears as written. `icon` is a bundled image. An SVG is drawn in the text color.

An entry that breaks these rules is skipped with a reason and can't be installed.

Installing checks the address, then connects once to ask the server what it offers. Nothing is saved at that point. The sheet shows every tool with the server's own name and description. A tool the server marks as read-only is a read, and anything else is a write. Install connects all of them: reads run, and writes follow the Make changes through connected services rule.

Entries are remote HTTP servers only. Listing a publisher is not a verification of the service. The list does not supply OAuth client details, so an OAuth entry still needs the publisher's preregistered public client in its configuration as described above.

A row written from the list may carry two optional keys, `publisher` and `source_url`. They are informational and a hand-written declaration can omit them.

Local stdio servers, a remote registry fetch, plugin packages and publisher verification are not part of this.

Run `mise run native-mcp-test` for schema, shared-authority and synthetic HTTP SDK tests, and `mise run check` for the repository regressions. The HTTP fixture binds only to loopback and makes no paid model calls. Synthetic test results do not establish live-service compatibility. See [SDK evaluation](MCP_SDK.md) for the exact dependency pin and transport boundaries.
