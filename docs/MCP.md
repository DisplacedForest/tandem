# Connected service tools

Vera uses the official Swift MCP client for explicitly configured remote read tools. Focused chat and the persistent workspace use the same enabled catalog and host permission checks. Existing built-in tools, memory and task approval remain in place.

No server is configured by default. Connecting a service does not authorize every tool it describes. Before configuring a service, review its maintained implementation, destination, read semantics, authentication requirements and compatibility. A server's read-only annotation is not permission to execute it.

The first implementation supports remote HTTPS without authentication. OAuth, credential transmission, local subprocess servers, automatic installation, server-initiated actions and MCP Events are not supported. Authentication-required servers remain unavailable with a setup message. Redirects, cookies and HTTP authentication challenges are refused.

A reviewed connection can be declared in `native_mcp_servers` in the existing configuration file:

```json
{
  "native_mcp_servers": [{
    "id": "215dccee-72ed-4bcc-9006-1b9e8da308cd",
    "name": "Reference service",
    "url": "https://reference.example/mcp",
    "read_tools": ["lookup_reference"],
    "scopes": ["focused", "assistant"],
    "timeout_seconds": 20
  }]
}
```

This example is not a deployed service. Use the reviewed server's real endpoint and exact approved tool names. Do not put credentials in its URL or this declaration. Configuration changes take effect after reopening Vera. Open Settings, Tools, then Connect. Enable the discovered read tool and Save. Connections are not reopened automatically after restart. Disconnect or disable a tool to revoke active access. Worker access requires an explicit `worker` scope in addition to the existing task approval.

Tool identities include the configured server identity, destination and remote name. Moving a server does not inherit the old destination's enabled tools. Discovery preserves complete argument schemas. Tool argument schemas require an explicit object root. Nested arrays and boolean schemas remain supported. Unsupported schemas remain visible but unavailable; the inspector shows the original schema. Supported schema constructs are documented in the source validator and covered by its fixtures. There is no schema flattening to the generic HTTP tool format. JSON numbers that cannot round-trip through the native numeric representation are refused before decoding, including integers beyond the exact safe range and excessive decimal precision. The SDK decodes some data-URL strings as binary values; those schemas and structured results are refused rather than silently rewritten.

Discovery is bounded to eight pages and 128 tools, each with a 32 KiB schema. Calls validate arguments before network dispatch, recheck current enablement and scope, and have a configured timeout of at most 20 seconds. Results exposed to the model are bounded to 4 KiB including source attribution. Narrow the query if a service returns too much data. A failed or canceled connection requires explicit reconnection; calls are never automatically replayed. Cancellation stops waiting and cancels the transport but cannot guarantee a remote server stopped work.

The persistent workspace accepts at most 16 enabled tools, 8 KiB of total catalog JSON and 2 KiB per description, with object-root schemas. A catalog beyond those bounds is refused in that workspace; disable unused tools or use a narrower service catalog. A task whose MCP authorization became stale after disconnect or a permission change stays refused on retry. Start a new explicitly approved task after reconnecting.

The first slice exposes only host-approved reads. Consequential actions remain unavailable through MCP and retain existing native confirmation boundaries. Changing a provider or execution path does not authorize a different tool, create a memory store, or replace the Python task authority.

Run `mise run native-mcp-test` for schema, shared-authority and synthetic HTTP SDK tests, and `mise run check` for the repository regressions. The HTTP fixture binds only to loopback and makes no paid model calls. Synthetic test results do not establish live-service compatibility. See [SDK evaluation](MCP_SDK.md) for the exact dependency pin and transport boundaries.
