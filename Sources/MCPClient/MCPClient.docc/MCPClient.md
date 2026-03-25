# ``MCPClient``

A lightweight, reusable Swift client for the Model Context Protocol (MCP).

## Overview

MCPClient provides a type-safe interface for communicating with MCP servers
using the JSON-RPC 2.0 protocol. It supports tool discovery and invocation,
resource reading, and prompt expansion over pluggable transports —
``HTTPSSETransport`` for remote servers and ``StdioTransport`` for local
development.

The library has zero external dependencies (Foundation only), uses Swift 6
strict concurrency throughout, and is designed for extraction into any
Swift project that needs MCP integration.

## Topics

### Essentials

- <doc:MCPClientGuide>
- ``MCPClientConnection``
- ``MCPClientProtocol``
- ``MCPTool``
- ``MCPToolResult``

### Resources

- <doc:ResourcesGuide>
- ``MCPResource``
- ``MCPResourceTemplate``
- ``MCPResourceContents``

### Prompts

- <doc:PromptsGuide>
- ``MCPPrompt``
- ``MCPPromptArgument``
- ``MCPPromptMessage``
- ``MCPPromptContent``
- ``MCPPromptResult``

### Transport

- <doc:TransportGuide>
- ``MCPTransport``
- ``HTTPSSETransport``
- ``StdioTransport``

### JSON-RPC Protocol

- ``JSONRPCRequest``
- ``JSONRPCResponse``
- ``JSONRPCNotification``
- ``JSONRPCError``

### Supporting Types

- ``AnyCodableValue``
- ``MCPAnnotations``
- ``MCPRole``
- ``MCPContent``
- ``InitializeResult``
- ``ServerCapabilities``
- ``ToolsCapability``
- ``ResourcesCapability``
- ``PromptsCapability``
- ``ServerInfo``

### Error Handling

- ``MCPError``
