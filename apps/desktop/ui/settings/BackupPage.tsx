import { signal, View, Scroll, cleanup } from "nsh";
import { Backup } from "passwordvault/native";
import { Btn, Group, OptionRow, Pill, Row, T, TextBox } from "../kit";
import { load, onLock, phase, settings, vaultInstance } from "../store";
import { exportBackup, importBackup, backupError, passwordSheet } from "../backup";
import { cxfExport, structuredImport } from "./backup-import";
import { c } from "../theme";

export function BackupPage() {
  const initialConfig = { url: "", username: "", password: "", folder: "PasswordVault", ...settings().webdav };
  const config = signal(initialConfig);
  const files = signal<any[]>([]);
  // Scoped per-operation states instead of one page-wide lock.
  const savingConfig = signal(false);
  const listing = signal(false);
  const transferring = signal(false);
  const expanded = signal(!initialConfig.url);
  const connected = signal(false);
  const status = signal("");
  const error = signal("");
  const query = signal("");
  cleanup(onLock(() => {
    config.set({ url: "", username: "", password: "", folder: "PasswordVault" });
    files.set([]);
    status.set("");
    error.set("");
  }));
  const hasServer = () => Boolean(config().url.trim());
  const request = async (action: string, extra: Record<string, unknown> = {}) =>
    JSON.parse(await Backup.webdav(vaultInstance, JSON.stringify({ action, config: config(), ...extra })));
  const run = async (action: "list" | "save") => {
    if ((action === "save" && savingConfig()) || (action === "list" && listing()) || transferring()) return;
    if (action === "save") savingConfig.set(true); else listing.set(true);
    error.set("");
    status.set(action === "save" ? "正在加密保存连接…" : "正在读取备份列表…");
    try {
      const result = await request(action);
      if (phase() !== "unlocked") return;
      if (action === "list") {
        files.set(result);
        connected.set(true);
        expanded.set(false);
        status.set(`列表已更新 · ${result.length} 份备份`);
      } else {
        settings.update((s) => ({ ...s, webdav: config() }));
        status.set("连接设置已加密保存");
      }
    } catch (e) {
      status.set("");
      error.set(backupError(e));
    } finally {
      if (action === "save") savingConfig.set(false); else listing.set(false);
    }
  };
  const field = (key: string, label: string, masked = false) => (
    <TextBox
      label={label}
      placeholder={label}
      value={config()[key] ?? ""}
      masked={masked}
      onChange={(v) => {
        if (savingConfig() || transferring()) return;
        config.update((s) => ({ ...s, [key]: v }));
        files.set([]);
        connected.set(false);
        status.set("");
      }}
    />
  );
  const restore = (file: any) => passwordSheet("恢复 WebDAV 备份", `${file.name}。旧版加密备份需要创建备份时的旧版主密码。`, false, async (password) => {
    if (transferring()) throw new Error("已有备份传输正在进行，请稍后重试。");
    transferring.set(true);
    try {
      const result = await request("restore", { url: file.url, password });
      if (phase() !== "unlocked") return;
      await load();
      status.set(`合并完成 · 新增或更新 ${result.imported ?? 0} 条`);
    } finally {
      transferring.set(false);
    }
  });
  const upload = () => passwordSheet("上传完整加密备份", "使用新的唯一文件名，不覆盖远端已有备份。", true, async (password) => {
    if (transferring()) throw new Error("已有备份传输正在进行，请稍后重试。");
    transferring.set(true);
    try {
      await request("upload", { password });
      if (phase() !== "unlocked") return;
      status.set("备份已上传");
      try {
        files.set(await request("list"));
        connected.set(true);
      } catch {
        error.set("备份已上传，列表刷新失败。请刷新列表，无需重复上传。");
      }
    } finally {
      transferring.set(false);
    }
  });
  const date = (file: any) => {
    const raw = file.modified || file.created;
    const n = Date.parse(raw);
    return Number.isFinite(n) ? new Date(n).toLocaleString() : "时间未知";
  };
  const filteredFiles = () =>
    files()
      .filter((f) => f.name.toLowerCase().includes(query().toLowerCase()))
      .sort((a, b) => (Date.parse(b.modified || b.created) || 0) - (Date.parse(a.modified || a.created) || 0));

  return (
    <View style={{ gap: 18 }}>
      <View style={{ gap: 4 }}>
        <T size={19} weight="600">备份与导入</T>
        <T size={12} color={c().muted}>备份文件使用单独的备份密码加密，与主密码无关。本机备份与导入始终离线可用。</T>
      </View>

      <View style={{ gap: 7 }}>
        <T size={12} weight="600" color={c().muted}>本机加密备份</T>
        <Group>
          <OptionRow title="导出加密备份" note="选择保存位置，生成新的加密备份文件">
            <Btn label="导出…" onPress={exportBackup} />
          </OptionRow>
          <OptionRow last title="从备份导入" note="较新记录优先，当前独有记录自动保留">
            <Btn label="导入…" onPress={importBackup} />
          </OptionRow>
        </Group>
      </View>

      <View style={{ gap: 7 }}>
        <T size={12} weight="600" color={c().muted}>WebDAV 云端备份</T>
        <Group>
          <View style={{ gap: 10, paddingVertical: 12 }}>
            <Row gap={8}>
              <Row gap={6} style={{ flex: 1, minWidth: 0 }} wrap>
                <T size={13} weight="600" lines={1}>{connected() ? config().url : "备份服务器"}</T>
                <Pill tone={connected() ? "ok" : hasServer() ? "info" : "neutral"}>
                  {connected() ? "已连接" : hasServer() ? "已填写地址" : "未配置"}
                </Pill>
              </Row>
              <Btn label={expanded() ? "收起连接" : "修改连接"} disabled={transferring()} onPress={() => expanded.set(!expanded())} />
            </Row>

            <If when={expanded()}>
              <View style={{ gap: 8, paddingTop: 4 }}>
                {field("url", "HTTPS 服务器地址")}
                {field("username", "服务器用户名")}
                {field("password", "WebDAV 登录密码", true)}
                {field("folder", "备份目录")}
                <T size={11.5} color={c().muted}>只允许 HTTPS，拒绝重定向，不使用 Cookie。服务器凭据加密保存，备份密码单独输入。</T>
                <Row gap={8} wrap>
                  <Btn label={savingConfig() ? "保存中…" : "保存连接设置"} disabled={savingConfig() || transferring() || !hasServer()} onPress={() => void run("save")} />
                  <If when={!hasServer()}><T size={11} color={c().muted}>请先填写 HTTPS 服务器地址</T></If>
                </Row>
              </View>
            </If>

            <Row gap={8} wrap style={{ paddingTop: 2 }}>
              <Btn label={listing() ? "刷新中…" : "连接并刷新"} disabled={listing() || transferring()} onPress={() => void run("list")} />
              <Btn label={transferring() ? "传输中…" : "立即备份…"} kind="primary" disabled={transferring()} onPress={upload} />
              <If when={!hasServer()}><T size={11} color={c().muted}>填写地址后可连接远端并上传</T></If>
            </Row>

            <If when={status()}><T size={12} color={c().muted}>{status()}</T></If>
            <If when={error()}><T size={12} color={c().red}>{error()}</T></If>

            <View style={{ borderTopWidth: 1, borderTopColor: c().line2, paddingTop: 10, gap: 8 }}>
              <If when={files().length > 0}>
                <TextBox placeholder="搜索备份文件" value={query()} onChange={(v) => query.set(v)} />
              </If>
              <Scroll style={{ maxHeight: 220 }}>
                <View>
                  {filteredFiles().map((file, idx, arr) => (
                    <OptionRow
                      last={idx === arr.length - 1}
                      title={file.name}
                      note={`${date(file)} · ${file.size == null ? "大小未知" : `${(file.size / 1024).toFixed(1)} KB`}`}
                    >
                      <Btn label="恢复…" disabled={transferring()} onPress={() => restore(file)} />
                    </OptionRow>
                  ))}
                  <If when={!files().length}>
                    <T size={12} color={c().muted}>
                      {listing() ? "正在从 WebDAV 读取清单…" : connected() ? "此目录还没有备份" : "连接后查看备份"}
                    </T>
                  </If>
                </View>
              </Scroll>
            </View>
          </View>
        </Group>
      </View>

      <View style={{ gap: 7 }}>
        <T size={12} weight="600" color={c().muted}>从其他密码管理器导入</T>
        <Group>
          <OptionRow title="CSV 文件" note="字段映射、预览与重复检测">
            <Btn label="选择 CSV…" onPress={() => structuredImport("csv")} />
          </OptionRow>
          <OptionRow title="1Password（.1pux）" note="保留分类、标签、自定义字段和支持的附件">
            <Btn label="选择 1PUX…" onPress={() => structuredImport("1pux")} />
          </OptionRow>
          <OptionRow last title="FIDO 凭据交换格式（CXF）" note="账号、密码、通行密钥（含 PRF）与验证码；仅支持 ES256 通行密钥">
            <Btn label="选择 CXF…" onPress={() => structuredImport("cxf")} />
          </OptionRow>
        </Group>
        <Group>
          <OptionRow last title="导出为 CXF" note="迁移到其他支持 CXF 的密码管理器；文件未加密，需要主密码">
            <Btn label="导出 CXF…" onPress={cxfExport} />
          </OptionRow>
        </Group>
      </View>
    </View>
  );
}
