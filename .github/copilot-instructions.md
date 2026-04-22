# Delphi MCP Server – Copilot Instructions

## Build

Requires **Delphi 12 Athens** or later. The project file is `src\MCPServer.dproj`.

```bat
build.bat                   # Debug Win32 (default)
build.bat Release Win64     # Release Win64
build.bat Debug Linux64     # Linux64 (uses MSBuild; requires PAServer)
```

Output lands in `<Platform>\<Config>\MCPServer.exe` (e.g., `Win32\Debug\MCPServer.exe`).  
`build.bat` hardcodes `DELPHI_PATH=C:\Program Files (x86)\Embarcadero\Studio\37.0` – update if your install differs.

Test with the MCP Inspector:
```bat
Win32\Debug\MCPServer.exe          # start server (HTTP on :3000)
npx @modelcontextprotocol/inspector # browse to http://localhost:3000/mcp
```

## Architecture

The server has two runtimes sharing the same JSON-RPC core:

| Transport | Entry point | Use case |
|-----------|-------------|----------|
| HTTP (Streamable HTTP + SSE) | `TMCPIdHTTPServer` | Claude Code, MCP Inspector |
| STDIO | `TMCPStdioTransport` | Codex, process-spawning clients |

HTTP now also carries **server-initiated client requests** for elicitation. `TMCPIdHTTPServer` uses a session-bound outbound queue delivered over GET + `Accept: text/event-stream`, while inbound client replies are correlated back to the waiting server workflow through `TMCPSessionManager`.

### Request flow

```
Client request
  → Transport layer (HTTP or STDIO)
  → TMCPJsonRpcProcessor.Process
  → IMCPManagerRegistry.GetManagerForMethod
  → IMCPCapabilityManager.ExecuteMethod
       ├── TMCPCoreManager   (initialize, ping)
       ├── TMCPToolsManager  (tools/list, tools/call)
       └── TMCPResourcesManager (resources/list, resources/read)
```

### Tool & Resource Registration

Tools and resources **self-register** in their unit's `initialization` block via `TMCPRegistry`. This means a tool/resource becomes available simply by including its unit in the `.dpr` uses list.

```pascal
initialization
  TMCPRegistry.RegisterTool('echo',
    function: IMCPTool
    begin
      Result := TEchoTool.Create;
    end);
```

`TMCPToolsManager` and `TMCPResourcesManager` query `TMCPRegistry` at runtime.

### Schema generation

Input/output schemas are generated automatically from RTTI on the params class. No manual schema writing is needed.

### Elicitation flow

- `TMCPSessionManager` owns per-session client capabilities, pending outbound requests, outbound SSE messages, and completed demo URL elicitations.
- `TMCPRequestContext` exposes the current `sessionId` to server code running inside a request so tools can call `TMCPElicitationService`.
- `TMCPElicitationService` is the shared API for `elicitation/create`, URL-required errors (`-32042`), and `notifications/elicitation/complete`.
- `TMCPJsonRpcProcessor` must preserve `EMCPJsonRpcError` codes/data so protocol errors survive tool execution and return as JSON-RPC errors rather than tool text.

## Key Conventions

### Creating a new tool

1. Create a params class and a tool class in `src\Tools\`:

```pascal
type
  TMyParams = class
  public
    [SchemaDescription('What this param does')]
    property Input: string read FInput write FInput;

    [Optional]
    [SchemaDescription('Optional count, default 1')]
    property Count: Integer read FCount write FCount;
  end;

  TMyTool = class(TMCPToolBase<TMyParams>)   // returns string
  protected
    function ExecuteWithParams(const Params: TMyParams): string; override;
  public
    constructor Create; override;
  end;
```

Use `TMCPToolBase<TParams, TResult>` when the result should be a typed object serialized to JSON.

2. Set `FName` and `FDescription` in the constructor.  
3. Self-register in `initialization`.  
4. Add the unit to `src\MCPServer.dpr` uses list.

If a tool needs user input through the MCP client, call `TMCPElicitationService` from inside `ExecuteWithParams`. The current implementation only supports this over **HTTP sessions** that negotiated `capabilities.elicitation`; STDIO does not yet support nested server-to-client requests.

### Creating a new resource

Extend `TMCPResourceBase<TData>`, set `FURI`, `FName`, `FDescription`, `FMimeType` in the constructor, and implement `GetResourceData`.

- `FMimeType = 'application/json'` → data is serialized via `TMCPSerializer`  
- Other MIME types → the base class reads a `Content: string` property via RTTI

### Params attributes

| Attribute | Effect |
|-----------|--------|
| `[SchemaDescription('...')]` | Adds `description` to the JSON schema |
| `[Optional]` | Marks the property as not required in the schema |
| `[SchemaEnum('a','b','c')]` | Adds an `enum` constraint (up to 4 values inline, or array overload) |

Property names are **lowercased** when mapped to JSON field names (handled by `TMCPSchemaGenerator.GetPropertyJsonName`).

### SSL / TLS

Toggle TaurusTLS (OpenSSL 3.x) vs standard Indy SSL (OpenSSL 1.0.2) with a compiler define in `src\Server\MCPServer.IdHTTPServer.pas`:

```pascal
{$DEFINE USE_TAURUS_TLS}   // comment out to fall back to Indy SSL
```

TaurusTLS is required for modern cipher suites (e.g., Cloudflare tunnels). Generate dev certs with `generate-ssl-cert.bat`.

### STDIO mode logging

In STDIO mode `TLogger.UseStdErr` is set to `True` so diagnostic output goes to stderr and does not corrupt the JSON-RPC stream on stdout.

### Error handling for protocol features

Use `EMCPJsonRpcError` when a feature must surface a real JSON-RPC error (for example `-32042` URL elicitation required). `TMCPToolsManager` is expected to re-raise `EMCPJsonRpcError` and only convert ordinary exceptions into tool-text errors.

### Source layout

```
src\
  MCPServer.dpr / .dproj   ← project files
  Core\       ← Logger, Settings, Registration, ManagerRegistry
  Protocol\   ← Types (attributes), JsonRpcProcessor, SchemaGenerator, Serializer
  Managers\   ← CoreManager, ToolsManager, ResourcesManager
  Server\     ← IdHTTPServer (HTTP transport), StdioTransport
  Tools\      ← Tool.Base + example tools (Echo, GetTime, ListFiles, Calculate)
  Resources\  ← Resource.Base + example resources (Logs, Project, Server)
  Http\       ← HTTP client helpers (executor, response parser)
```
