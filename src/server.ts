import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { createServer } from "./mcp-server.js";

async function main() {
  const server = createServer();
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("ubuntu-shell MCP server started and listening on stdio");
}

main().catch((err) => {
  console.error("Fatal error starting ubuntu-shell MCP server:", err);
  process.exit(1);
});
