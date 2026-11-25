// Settings: one window-wide dialog with a section list. Sections that depend on
// native services not yet ported say so instead of pretending to work.
import { cleanup, Clipboard, openUrl, setColorScheme, signal, Storage, View, Scroll } from "nsh";
import { Dialog } from "nsh/base";
import { Platform } from "passwordvault/native";
import { Icon, type IconName } from "./icons";
import { Banner, Btn, Group, OptionRow, Pill, Row, SegmentedChoice, T, TextBox, Toggle } from "./kit";
import { coreApi, errorText, onLock, saveSettings, settings, toast, vaultDirectory } from "./store";
import { c, radius, TEXT_SCALES, textScale } from "./theme";
import { appVersion } from "./version";
import { clipboardSeconds, DENSITY_LABEL, hideFromCapture, listDensity, noteLineNumbers, quickCloseAfterCopy, setClipboardSeconds, setHideFromCapture, setListDensity, setNoteLineNumbers, setQuickCloseAfterCopy, setTrayIcon, trayIcon, type ListDensity } from "./preferences";
import { SHORTCUT_LABEL, setShortcut, shortcut, shortcutAvailable, type ShortcutChoice } from "./hotkey";
import { isMac, desktopCapabilities, biometricAvailability, biometricEnabled, biometricError, disableBiometrics, enableBiometrics, loginItemStatus, openLoginItemSettings, setLoginItem, type LoginStatus } from "./native";
import { openSheet, SheetFooter, SheetTitle } from "./kit";
import { BackupPage } from "./settings/BackupPage";
import { RecoverySettings } from "./recovery";
import { RelayPage } from "./relay";
import { BrowserPage } from "./browser";

type Tab = "general" | "security" | "backup" | "relay" | "browser" | "about";
const TABS: [Tab, string, IconName][] = [
  ["general", "通用", "gear"],
  ["security", "安全", "lock"],
  ["backup", "备份与导入", "archive"],
  ["relay", "同步与设备", "sync"],
  ["browser", "浏览器", "browser"],
  ["about", "关于", "info"],
];
const open = signal(false);
const tab = signal<Tab>("general");
const appearance = signal<"system" | "light" | "dark">("system");

export function openSettings(t?: Tab) {
  if (t) tab.set(t);
  open.set(true);
}
export const settingsOpen = () => open();
export const closeSettings = () => open.set(false);

function Title(props: { title: string; text: string }) {
  return (
    <View style={{ marginBottom: 14, gap: 4 }}>
      <T size={19} weight="600">{props.title}</T>
      <T size={12} color={c().muted}>{props.text}</T>
    </View>
  );
}
function GroupTitle(props: { text: string }) {
  return <T size={12} weight="600" style={{ marginTop: 16, marginBottom: 7 }}>{props.text}</T>;
}

function General() {
  return (
    <>
      <Title title="通用" text="外观与剪贴板。" />
      <GroupTitle text="外观" />
      <Group>
        <OptionRow title="主题">
          <SegmentedChoice
            testID="setting-theme"
            value={appearance()}
            options={[["system", "跟随系统"], ["light", "浅色"], ["dark", "深色"]]}
            onChange={(next) => { appearance.set(next); setColorScheme(next); }}
          />
        </OptionRow>
        <OptionRow title="文字大小" note="调整整个界面的文字与控件大小">
          <SegmentedChoice
            testID="setting-text-scale"
            value={String(textScale())}
            options={TEXT_SCALES.map(([v, l]) => [String(v), l] as const)}
            onChange={(v) => { textScale.set(Number(v)); void Storage.setItem("textScale", v); }}
          />
        </OptionRow>
        <OptionRow title="列表密度" note="紧凑模式在列表中显示更多项目">
          <SegmentedChoice
            testID="setting-list-density"
            value={listDensity()}
            options={(Object.keys(DENSITY_LABEL) as ListDensity[]).map((k) => [k, DENSITY_LABEL[k]] as const)}
            onChange={(v) => setListDensity(v)}
          />
        </OptionRow>
        <OptionRow last title="语言" note="其他语言将在本地化接入后提供">
          <Pill tone="neutral">简体中文</Pill>
        </OptionRow>
      </Group>
      <GroupTitle text="笔记编辑器" />
      <Group>
        <Toggle last title="显示行号" note="在笔记编辑与 Markdown 源码左侧显示行号，也可在编辑器工具栏随时切换"
          checked={noteLineNumbers()} onChange={setNoteLineNumbers} />
      </Group>
      <GroupTitle text="剪贴板" />
      <Group>
        <OptionRow last title="自动清除剪贴板" note="清除前确认内容未被替换；只影响本机">
          <SegmentedChoice
            testID="setting-clipboard"
            compact
            wrap
            value={String(clipboardSeconds())}
            options={[["15", "15 秒"], ["30", "30 秒"], ["60", "1 分"], ["120", "2 分"], ["0", "不清除"]]}
            onChange={(v) => setClipboardSeconds(Number(v))}
          />
        </OptionRow>
      </Group>
      <If when={desktopCapabilities.loginItem}><GroupTitle text="启动" />
      <Group><LoginItemRow /></Group></If>
      <GroupTitle text={isMac ? "菜单栏" : "通知区域"} />
      <Group>
        <Toggle last title={isMac ? "在菜单栏显示图标" : "在通知区域显示图标"} note="提供快速访问、锁定和打开主窗口；图标菜单不显示任何资料"
          checked={trayIcon()} onChange={setTrayIcon} />
      </Group>
      <If when={desktopCapabilities.globalHotkeys}><GroupTitle text="快速访问" />
      <Group>
        <OptionRow last title="全局快捷键" note={shortcutAvailable() ? "在任何应用中打开快速访问；锁定时只唤起主窗口" : "该快捷键已被其他应用占用，请换一个"}>
          <SegmentedChoice
            testID="setting-shortcut"
            compact
            wrap
            value={shortcut()}
            options={(Object.keys(SHORTCUT_LABEL) as ShortcutChoice[]).map((k) => [k, SHORTCUT_LABEL[k]] as const)}
            onChange={(v) => void setShortcut(v)}
          />
        </OptionRow>
      </Group></If>
      <GroupTitle text="快速访问面板" />
      <Group>
        <Toggle last title="复制后关闭快速访问" note="关闭后，复制密码、验证码或用户名时面板保持打开，便于连续复制"
          checked={quickCloseAfterCopy()} onChange={setQuickCloseAfterCopy} />
      </Group>
    </>
  );
}

const loginStatus = signal<LoginStatus>("notRegistered");
function LoginItemRow() {
  loginStatus.set(loginItemStatus());
  const note = () =>
    loginStatus() === "requiresApproval" ? "等待你在“系统设置 › 通用 › 登录项”中允许"
      : loginStatus() === "notFound" ? "系统找不到这个应用，请从“应用程序”文件夹启动后再开启"
        : "登录这台 Mac 后自动打开 PasswordVault（保持锁定，需要解锁后才能查看资料）";
  return (
    <>
      <Toggle title="登录时启动" note={note()} checked={loginStatus() === "enabled" || loginStatus() === "requiresApproval"}
        onChange={(on) => {
          try { loginStatus.set(setLoginItem(on)); } catch (e) { loginStatus.set(loginItemStatus()); toast(`无法更改登录项：${String(e)}`); }
        }} />
      <If when={loginStatus() === "requiresApproval"}>
        <OptionRow title="需要系统批准" note="macOS 要求你在系统设置中允许登录项"><Btn label="打开登录项设置" onPress={openLoginItemSettings} /></OptionRow>
      </If>
    </>
  );
}

const bio = signal(false);

/**
 * First-run offer after creating a vault. The just-entered master password is held
 * only while this sheet is open and is dropped on close or lock.
 */
export function offerBiometricsAfterCreate(password: string) {
  openSheet({ width: 440, render: (close) => <BiometricOffer password={password} close={close} /> });
}

function BiometricOffer(props: { password: string; close: () => void }) {
  let held: string | null = props.password;
  const busy = signal(false);
  const error = signal("");
  const drop = () => { held = null; };
  cleanup(drop);
  cleanup(onLock(() => { drop(); props.close(); }));
  const later = () => { drop(); props.close(); };
  const enable = async () => {
    if (busy() || !held) return;
    busy.set(true);
    error.set("");
    try {
      await enableBiometrics(held);
      drop();
      bio.set(true);
      props.close();
      toast("Touch ID 已启用");
    } catch (e) {
      error.set(biometricError(e));
    } finally {
      busy.set(false);
    }
  };
  return (
    <View style={{ gap: 10 }}>
      <SheetTitle title="使用 Touch ID 解锁？" text="解锁凭据保存在这台 Mac 的钥匙串中，需要生物识别才能读取，不会同步到其他设备。主密码仍可随时使用。" />
      <If when={error()}><T size={12} color={c().red}>{error()}</T></If>
      <SheetFooter>
        <Btn label="稍后在设置中启用" disabled={busy()} onPress={later} />
        <Btn label={busy() ? "正在启用…" : "启用 Touch ID"} kind="primary" disabled={busy()} onPress={enable} />
      </SheetFooter>
    </View>
  );
}

function askEnableBiometrics(reverify = false) {
  const pw = signal("");
  const busy = signal(false);
  const error = signal("");
  openSheet({
    width: 440,
    render: (close) => {
      const go = async () => {
        if (!pw() || busy()) return;
        busy.set(true);
        error.set("");
        try {
          await enableBiometrics(pw());
          pw.set("");
          bio.set(true);
          close();
          toast(reverify ? "Touch ID 已重新验证" : "Touch ID 已启用");
        } catch (e) {
          error.set(String(e).includes("Authentication") ? "主密码不正确。" : biometricError(e));
        } finally {
          busy.set(false);
        }
      };
      return (
        <View style={{ gap: 10 }}>
          <SheetTitle title={reverify ? "重新验证 Touch ID" : "启用 Touch ID"} text={reverify
            ? "应用签名或钥匙串变化后，Touch ID 可能无法读取旧凭据。输入当前主密码，重新保存这台 Mac 的解锁凭据。"
            : "输入当前主密码确认。解锁凭据保存在这台 Mac 的钥匙串中，需要指纹才能读取，不会同步到其他设备。"} />
          <TextBox value={pw()} onChange={(v) => pw.set(v)} masked autoFocus placeholder="当前主密码" onSubmit={go} />
          <T size={12} color={c().red}>{error()}</T>
          <SheetFooter>
            <Btn label="取消" onPress={close} />
            <Btn label={busy() ? (reverify ? "正在验证…" : "正在启用…") : reverify ? "重新验证" : "启用"} kind="primary" disabled={!pw() || busy()} onPress={go} />
          </SheetFooter>
        </View>
      );
    },
  });
}

function Security() {
  try {
    bio.set(biometricEnabled());
  } catch {
    bio.set(false);
  }
  const minutes = () => (settings().macNeverIdleLock ? 0 : Number(settings().autoLockMinutes ?? 60));
  const current = signal("");
  const next = signal("");
  const again = signal("");
  const busy = signal(false);
  const problem = () => (next() && next().length < 10 ? "新主密码至少需要 10 个字符。" : again() && next() !== again() ? "两次输入的新主密码不一致。" : "");
  const change = async () => {
    if (busy() || problem() || !current() || !next()) return;
    busy.set(true);
    try {
      await coreApi.changePassword(current(), next());
      current.set(""); next.set(""); again.set("");
      toast("主密码已更新");
    } catch (e) {
      toast(errorText(e));
    } finally {
      busy.set(false);
    }
  };
  return (
    <>
      <Title title="安全" text="解锁与自动锁定。" />
      <GroupTitle text="自动锁定" />
      <Group>
        <OptionRow title="闲置后锁定" note="“从不”只关闭闲置锁定；手动锁定仍然生效">
          <SegmentedChoice
            testID="setting-idle-lock"
            compact
            wrap
            value={String(minutes())}
            options={[["1", "1分"], ["5", "5分"], ["15", "15分"], ["30", "30分"], ["60", "1小时"], ["0", "从不"]]}
            onChange={(v) => void (v === "0" ? saveSettings({ macNeverIdleLock: true }) : saveSettings({ macNeverIdleLock: false, autoLockMinutes: Number(v) }))}
          />
        </OptionRow>
        <Toggle title="电脑睡眠时锁定" checked={settings().macLockOnSleep !== false} onChange={(v) => void saveSettings({ macLockOnSleep: v })} />
        <Toggle title="屏幕锁定、屏保或切换用户时锁定" checked={settings().macLockOnScreenLock !== false} onChange={(v) => void saveSettings({ macLockOnScreenLock: v })} />
      </Group>
      <If when={isMac}><GroupTitle text="解锁" />
      <Group>
        <Toggle title="使用 Touch ID 解锁"
          note={!biometricAvailability() ? "这台 Mac 没有可用的 Touch ID" : bio() ? "已启用 · 重启后首次仍可用主密码" : "启用前需要输入当前主密码"}
          checked={bio()} disabled={!biometricAvailability()}
          onChange={(v) => (v ? askEnableBiometrics() : void disableBiometrics().then(() => { bio.set(false); toast("Touch ID 已停用"); }, (e) => toast(biometricError(e))))} />
        <If when={bio() && biometricAvailability()}>
          <OptionRow title="重新验证 Touch ID" note="签名或钥匙串变化后使用"><Btn testID="reverify-touch-id" label="重新验证…" onPress={() => askEnableBiometrics(true)} /></OptionRow>
        </If>
      </Group></If>
      <If when={desktopCapabilities.captureProtection}><GroupTitle text="隐私" />
      <Group>
        <Toggle title="截屏、录屏和屏幕共享时隐藏窗口" note="开启后，截图、录屏和会议共享中看不到 PasswordVault 的窗口；只影响这台电脑"
          checked={hideFromCapture()} onChange={setHideFromCapture} />
      </Group></If>
      <GroupTitle text="修改主密码" />
      <Group style={{ paddingVertical: 12, gap: 8 }}>
        <TextBox value={current()} onChange={(v) => current.set(v)} masked placeholder="当前主密码" />
        <TextBox value={next()} onChange={(v) => next.set(v)} masked placeholder="新主密码（至少 10 个字符）" />
        <TextBox value={again()} onChange={(v) => again.set(v)} masked placeholder="确认新主密码" onSubmit={change} />
        <Row style={{ justifyContent: "space-between" }}>
          <T size={12} color={c().red}>{problem()}</T>
          <Btn label={busy() ? "正在修改…" : "修改主密码"} kind="primary" disabled={!current() || !next() || !!problem() || next() !== again()} onPress={change} />
        </Row>
      </Group>
      <GroupTitle text="本地数据" />
      <Group>
        <OptionRow last title="数据目录" note={vaultDirectory}><Btn label="打开数据目录" onPress={() => Platform.openVaultFolder()} /></OptionRow>
      </Group>
    </>
  );
}

function About() {
  return (
    <>
      <Title title="关于" text="" />
      <Group style={{ paddingVertical: 14 }}>
        <T size={16} weight="600">PasswordVault</T>
        <T size={12} color={c().muted}>版本 {appVersion} · Native Shell 预览 · {isMac ? "macOS 14+ · Apple Silicon" : "Windows · x64"}</T>
        <T size={12} color={c().muted}>加密核心 vault-core · SQLCipher</T>
      </Group>
      <View style={{ height: 12 }} />
      <Group>
        <OptionRow title="发布说明" note="在 GitHub Releases 查看各版本变更与下载">
          <Btn label="打开" onPress={() => openLink(`${REPO}/releases`)} />
        </OptionRow>
        <OptionRow title="许可与第三方声明" note="MIT 许可；附带依赖的许可声明">
          <Btn label="打开" onPress={() => openLink(`${REPO}/blob/main/config/release/THIRD_PARTY_NOTICES.md`)} />
        </OptionRow>
        <OptionRow title="隐私说明" note="资料只在本机加密保存；只在你主动操作（同步、备份、泄露检查）时联网，不收集使用数据">
          <Btn label="查看" onPress={() => openLink(`${REPO}#readme`)} />
        </OptionRow>
        <OptionRow last title="复制诊断信息" note="仅包含版本与系统信息，不含资料、路径或账号">
          <Btn testID="copy-diagnostics" label="复制" onPress={() => void Clipboard.writeText(diagnostics()).then(r => toast(r === "failed" ? "无法写入剪贴板" : "已复制诊断信息"), () => toast("无法写入剪贴板"))} />
        </OptionRow>
      </Group>
      <View style={{ height: 12 }} />
      <Banner tone="warn" title="尚未完成独立安全审计">请保留加密备份；完整限制见 docs/security/SECURITY_MODEL.md。</Banner>
    </>
  );
}

const REPO = "https://github.com/JunWeiUp/PasswordVault";
const openLink = (url: string) => void openUrl(url).catch(() => toast("无法打开链接"));
/** Version and platform only: never vault content, paths, accounts or device names. */
export function diagnostics(): string {
  return [`PasswordVault ${appVersion}`, `Platform: ${isMac ? "macOS" : "Windows"}`, "UI: Native Shell 0.7.0"].join("\n");
}

const PAGES: Record<Tab, () => any> = {
  general: General,
  security: Security,
  backup: () => <View style={{ gap: 20 }}><BackupPage /><RecoverySettings /></View>,
  relay: RelayPage,
  browser: BrowserPage,
  about: About,
};

export function SettingsHost() {
  return (
    <If when={open()}>
      <Dialog open animation="fade" onOpenChange={({ open: visible }) => !visible && open.set(false)} backdropStyle={{ backgroundColor: c().backdrop }}
        style={{ alignSelf: "center", marginTop: 60, width: 900, height: 640, maxHeight: "90%", flexDirection: "row", backgroundColor: c().surface, borderRadius: radius.sheet, borderWidth: 1, borderColor: c().line, overflow: "hidden" }}>
        <View style={{ width: 200, backgroundColor: c().side, borderRightWidth: 1, borderRightColor: c().sideLine, padding: 10, paddingTop: 20 }}>
          <T size={13} weight="600" style={{ marginLeft: 10, marginBottom: 12 }}>设置</T>
          {TABS.map(([k, label, icon]) => (
            <View role="button" accessibilityState={{ selected: tab() === k }} onPress={() => tab.set(k)}
              style={{ flexDirection: "row", alignItems: "center", gap: 10, height: 32, paddingHorizontal: 10, borderRadius: 7, backgroundColor: tab() === k ? c().blueLine : "transparent", cursor: "pointer" }}
              hoverStyle={tab() === k ? undefined : { backgroundColor: c().field }}>
              <Icon name={icon} size={16} tint={tab() === k ? c().blue : c().ink2} />
              <T weight={tab() === k ? "600" : "400"} color={tab() === k ? c().blue : c().ink2}>{label}</T>
            </View>
          ))}
          <View style={{ flex: 1 }} />
          <Btn label="关闭" kind="ghost" icon="x" onPress={() => open.set(false)} />
        </View>
        <Scroll style={{ flex: 1 }} contentStyle={{ padding: 28 }}>
          <Each of={[tab()]} key={(t) => t}>
            {(t) => {
              const Page = PAGES[t()];
              return <Page />;
            }}
          </Each>
        </Scroll>
      </Dialog>
    </If>
  );
}
