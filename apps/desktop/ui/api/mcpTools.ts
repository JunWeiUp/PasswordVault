// Single source of truth for MCP tool metadata, shared directly with helpers/pv-mcp.
// Editing apps/desktop/src/ai/tools.schema.json updates both the MCP protocol and UI.
import schema from "../../src/ai/tools.schema.json";

export type McpToolSpec = {
  name: string;
  uiSummary: string;
  readOnly: boolean;
  description: string;
};

export const MCP_INSTRUCTIONS: string = schema.instructions;
export const MCP_TOOLS: readonly McpToolSpec[] = schema.tools.map((t) => ({
  name: t.name,
  uiSummary: t.uiSummary,
  readOnly: t.readOnly,
  description: t.description,
}));

export const MCP_TOOL_BY_NAME: Record<string, McpToolSpec> = Object.fromEntries(
  MCP_TOOLS.map((t) => [t.name, t]),
);
