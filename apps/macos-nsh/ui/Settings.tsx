// Settings: one window-wide dialog with a section list. Sections that depend on
// native services not yet ported say so instead of pretending to work.
import { setColorScheme, signal, Storage, View, Scroll } from "nsh";
import { Dialog } from "nsh/base";
import { Menu } from "nsh/desktop";
import { Platform } from "passwordvault/native";
import { Icon, type IconName } from "./icons";
import { Banner, Btn, Group, OptionRow, Row, T, TextBox, Toggle } from "./kit";
import { call, errorText, saveSettings, settings, toast, vaultDirectory } from "./store";
import { c, radius, TEXT_SCALES, textScale } from "./theme";
import { appVersion } from "./version";
import { SHORTCUT_LABEL, setShortcut, shortcut, shortcutAvailable, type ShortcutChoice } from "./hotkey";
import { biometricAvailability, biometricEnabled, biometricError, disableBiometrics, enableBiometrics } from "./native";
import { openSheet, SheetFooter, SheetTitle } from "./kit";
import { BackupPage } from "./settings/BackupPage";
import { RecoverySettings } from "./recovery";
import { RelayPage } from "./relay";
import { BrowserPage } from "./browser";
import { AiPage } from "./ai";

type Tab = "general" | "security" | "backup" | "relay" | "browser" | "ai" | "about";
const TABS: [Tab, string, IconName][] = [
  ["general", "通用", "gear"],
  ["security", "安全", "lock"],
  ["backup", "备份与导入", "archive"],
  ["relay", "同步与设备", "sync"],
  ["browser", "浏览器", "browser"],
  ["ai", "AI 访问", "spark"],
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

function Picker(props: { value: string; options: [string, string][]; onChange: (v: string) => void }) {
  const label = () => props.options.find(([v]) => v === props.value)?.[1] ?? props.value;
  return (
    <View role="button" accessibilityLabel={label()} onPress={() => void Menu.popup(props.options.map(([v, l]) => ({ label: l, checked: v === props.value, onSelect: () => props.onChange(v) })))}
      style={{ flexDirection: "row", alignItems: "center", gap: 6, borderWidth: 1, borderColor: c().line, borderRadius: radius.control, paddingHorizontal: 10, height: 28, minWidth: 140, cursor: "pointer" }}
      hoverStyle={{ backgroundColor: c().blueSoft }}>
      <T size={12.5} style={{ flex: 1 }}>{label()}</T>
      <Icon name="chevd" size={12} tint={c().muted} />
    </View>
  );
}

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
function NotYet(props: { what: string }) {
  return <Banner tone="info" title="尚未接入此预览版">{props.what}仍由现有 SwiftUI 版提供。原生能力移植完成后在此开放，数据格式保持不变。</Banner>;
}

function General() {
  return (
    <>
      <Title title="通用" text="外观与剪贴板。" />
      <GroupTitle text="外观" />
      <Group>
        <OptionRow title="主题">
          <Picker value={appearance()} options={[["system", "跟随系统"], ["light", "浅色"], ["dark", "深色"]]}
            onChange={(v) => { appearance.set(v as any); setColorScheme(v as any); }} />
        </OptionRow>
        <OptionRow title="文字大小" note="调整整个界面的文字与控件大小">
          <Picker value={String(textScale())} options={TEXT_SCALES.map(([v, l]) => [String(v), l] as [string, string])}
            onChange={(v) => { textScale.set(Number(v)); void Storage.setItem("textScale", v); }} />
        </OptionRow>
        <OptionRow title="语言" note="其他语言将在本地化接入后提供"><Picker value="zh" options={[["zh", "简体中文"]]} onChange={() => {}} /></OptionRow>
      </Group>
      <GroupTitle text="剪贴板" />
      <Group>
        <OptionRow title="自动清除剪贴板" note="清除前确认内容未被替换"><T size={12.5} color={c().muted}>30 秒</T></OptionRow>
      </Group>
      <GroupTitle text="快速访问" />
      <Group>
        <OptionRow title="全局快捷键" note={shortcutAvailable() ? "在任何应用中打开快速访问；锁定时只唤起主窗口" : "该快捷键已被其他应用占用（例如正在运行的 SwiftUI 版），请换一个"}>
          <Picker value={shortcut()} options={(Object.keys(SHORTCUT_LABEL) as ShortcutChoice[]).map((k) => [k, SHORTCUT_LABEL[k]])} onChange={(v) => void setShortcut(v as ShortcutChoice)} />
        </OptionRow>
      </Group>
    </>
  );
}

const bio = signal(false);

function askEnableBiometrics() {
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
          toast("Touch ID 已启用");
        } catch (e) {
          error.set(String(e).includes("Authentication") ? "主密码不正确。" : biometricError(e));
        } finally {
          busy.set(false);
        }
      };
      return (
        <View style={{ gap: 10 }}>
          <SheetTitle title="启用 Touch ID" text="输入当前主密码确认。解锁凭据保存在这台 Mac 的钥匙串中，需要指纹才能读取，不会同步到其他设备。" />
          <TextBox value={pw()} onChange={(v) => pw.set(v)} masked autoFocus placeholder="当前主密码" onSubmit={go} />
          <T size={12} color={c().red}>{error()}</T>
          <SheetFooter>
            <Btn label="取消" onPress={close} />
            <Btn label={busy() ? "正在启用…" : "启用"} kind="primary" disabled={!pw() || busy()} onPress={go} />
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
      await call({ op: "change-password", currentPassword: current(), newPassword: next() });
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
          <Picker value={String(minutes())} options={[["1", "1 分钟"], ["5", "5 分钟"], ["15", "15 分钟"], ["30", "30 分钟"], ["60", "1 小时"], ["0", "从不"]]}
            onChange={(v) => void (v === "0" ? saveSettings({ macNeverIdleLock: true }) : saveSettings({ macNeverIdleLock: false, autoLockMinutes: Number(v) }))} />
        </OptionRow>
        <Toggle title="Mac 睡眠时锁定" checked={settings().macLockOnSleep !== false} onChange={(v) => void saveSettings({ macLockOnSleep: v })} />
        <Toggle title="屏幕锁定、屏保或切换用户时锁定" checked={settings().macLockOnScreenLock !== false} onChange={(v) => void saveSettings({ macLockOnScreenLock: v })} />
      </Group>
      <GroupTitle text="解锁" />
      <Group>
        <Toggle title="使用 Touch ID 解锁"
          note={!biometricAvailability() ? "这台 Mac 没有可用的 Touch ID" : bio() ? "已启用 · 重启后首次仍可用主密码" : "启用前需要输入当前主密码"}
          checked={bio()} disabled={!biometricAvailability()}
          onChange={(v) => (v ? askEnableBiometrics() : void disableBiometrics().then(() => { bio.set(false); toast("Touch ID 已停用"); }, (e) => toast(biometricError(e))))} />
      </Group>
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
        <OptionRow title="数据目录" note={vaultDirectory}><Btn label="在 Finder 中显示" onPress={() => Platform.openVaultFolder()} /></OptionRow>
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
        <T size={12} color={c().muted}>版本 {appVersion} · Native Shell 预览 · macOS 14+ · Apple Silicon</T>
        <T size={12} color={c().muted}>加密核心 vault-core · SQLCipher</T>
      </Group>
      <View style={{ height: 12 }} />
      <Banner tone="warn" title="尚未完成独立安全审计">请保留加密备份；完整限制见 docs/SECURITY_MODEL.md。此预览版与 SwiftUI 版并行开发，尚未达到功能对等。</Banner>
    </>
  );
}

const PAGES: Record<Tab, () => any> = {
  general: General,
  security: Security,
  backup: () => <><BackupPage /><RecoverySettings /></>,
  relay: RelayPage,
  browser: BrowserPage,
  ai: AiPage,
  about: About,
};

export function SettingsHost() {
  return (
    <If when={open()}>
      <Dialog open animation="fade" onOpenChange={(o) => !o && open.set(false)} backdropStyle={{ backgroundColor: c().backdrop }}
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
