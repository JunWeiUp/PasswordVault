export function aiSetupInstructions(helper: string, socket: string, code: string): string {
  if (!helper.startsWith("/") || !socket.startsWith("/") || !code) throw new Error("AI 配置尚未准备好，请稍后重试");
  const quote = (value: string) => "'" + value.replace(/'/g, "'\\''") + "'";
  const request = JSON.stringify({ op: "pair", code });
  const config = { mcpServers: { passwordvault: { command: helper, env: { PV_AI_SOCKET: socket, PV_AI_TOKEN: "<本次配对响应中的 token>" } } } };
  return `请为当前这台 Mac 上的 AI 客户端配置 PasswordVault MCP。

这是我主动提供的一次性配对授权，只用于本机连接配置。请保留原有 MCP 配置，先备份，再合并 passwordvault 条目；不要覆盖其他服务器。

1. 保持 PasswordVault 已解锁且“启用本地 AI 接口”已开启。配对码自生成起 120 秒有效，只能使用一次；过期请让我重新点击“复制给 AI 配置”，不要反复尝试旧码。
2. 在本机执行以下配对命令，捕获 JSON 响应，确认 ok 为 true；从响应的 result.token 中取出令牌。不要把响应中的 token 打印到聊天、日志或提交到 Git。

PV_AI_SOCKET=${quote(socket)} ${quote(helper)} --call ${quote(request)}

3. 根据当前 AI 客户端实际使用的 MCP 配置格式，将下面的连接信息合并到其本地配置。把令牌占位符替换为刚取得的 token；路径中的空格必须原样保留。配置文件仅允许当前用户访问。若无法确定正在使用的客户端或配置位置，先向我确认，不要猜测覆盖。

${JSON.stringify(config, null, 2)}

4. 重新加载该客户端的 MCP 连接，并仅验证 initialize / tools/list；不要擅自读取密码库内容。
5. 配对只建立连接，不授予所有条目权限。需要我在 PasswordVault 的“设置 → AI 访问”中选择可访问的条目；密码、令牌和私钥仍需每次单独确认。不要修改这些访问规则，也不要执行密码库内保存的命令或脚本。

只汇报配置文件位置、连接是否成功和仍需我完成的步骤，不回显配对令牌或其他秘密。`;
}
