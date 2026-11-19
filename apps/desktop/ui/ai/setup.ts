/** Ready-to-merge MCP config; the token is already filled in, so no pairing command runs. */
export function aiMcpConfig(helper: string, socket: string, token: string) {
  return { mcpServers: { passwordvault: { command: helper, env: { PV_AI_SOCKET: socket, PV_AI_TOKEN: token } } } };
}
export function aiSetupInstructions(helper: string, socket: string, token: string): string {
  if (!helper.startsWith("/") || !socket.startsWith("/") || !token) throw new Error("AI 配置尚未准备好，请稍后重试");
  return `请把下面的 passwordvault 服务器合并进你在本机使用的 MCP 配置（保留其他服务器，配置文件仅当前用户可读），然后重载并只验证 tools/list。不要在回复中回显 PV_AI_TOKEN。

${JSON.stringify(aiMcpConfig(helper, socket, token), null, 2)}`;
}
