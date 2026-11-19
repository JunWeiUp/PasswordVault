// Locked and first-run screens. No vault content is mounted here.
import { signal, View } from "nsh";
import { Icon } from "./icons";
import { Banner, Btn, IconBtn, Row, Strength, strengthOf, T, TextBox } from "./kit";
import { create, errorText, unlock, load, vaultDirectory } from "./store";
import { isMac, biometricAvailability, biometricEnabled, biometricError, unlockWithBiometrics } from "./native";
import { c } from "./theme";
import { askRecoveryReset, askEmergencyRestore } from "./recovery";
import { importBackup } from "./backup";
import { offerBiometricsAfterCreate } from "./Settings";
import { shouldOfferBiometrics } from "./biometric-offer";
import { Logo } from "./Sidebar";

function Centered(props: { children: any; width?: number }) {
  return (
    <View style={{ flex: 1, alignItems: "center", justifyContent: "center", backgroundColor: c().soft2 }}>
      <View style={{ width: props.width ?? 400, gap: 0 }}>{props.children}</View>
    </View>
  );
}

// Module scope: these outlive the screen, which unmounts as soon as unlock succeeds.
const password = signal("");
const error = signal("");
const busy = signal(false);

let unlockField: any;

export function LockScreen() {
  const showPassword = signal(false);
  let touchEnabled = false;
  try { touchEnabled = biometricAvailability() && biometricEnabled(); } catch { /* Master password stays available. */ }
  const touchUnlock = async () => {
    if (busy()) return;
    busy.set(true);
    error.set("");
    try { await unlockWithBiometrics(); await load(); password.set(""); showPassword.set(false); }
    catch (e) { error.set(biometricError(e)); }
    finally { busy.set(false); }
  };
  const submit = async () => {
    if (!password() || busy()) return;
    busy.set(true);
    error.set("");
    try {
      await unlock(password());
      password.set("");
      showPassword.set(false);
    } catch (e) {
      // Start the next attempt from an empty field instead of editing a wrong secret.
      password.set("");
      error.set(errorText(e));
      // Keep typing in the field after a wrong attempt.
      setTimeout(() => unlockField?.focus?.(), 0);
    } finally {
      busy.set(false);
    }
  };
  return (
    <Centered>
      <View style={{ alignItems: "center", gap: 6, marginBottom: 24 }}>
        <Logo size={72} />
        <T size={22} weight="600" style={{ marginTop: 14 }}>PasswordVault 已锁定</T>
        <T color={c().muted}>解锁以访问你的笔记和密码</T>
      </View>
      <Row gap={8}>
        <View style={{ flex: 1 }}>
          <TextBox ref={(r) => (unlockField = r)} testID="unlock-password" value={password()} onChange={(v) => password.set(v)} masked={!showPassword()} autoFocus placeholder="主密码" onSubmit={submit} />
        </View>
        <IconBtn icon="eye" label={showPassword() ? "隐藏主密码" : "显示主密码"} tint={showPassword() ? c().blue : c().muted} onPress={() => showPassword.update((s) => !s)} />
        <Btn label={busy() ? "正在解锁…" : "解锁"} kind="primary" disabled={!password() || busy()} onPress={submit} />
      </Row>
      <View style={{ minHeight: 22, marginTop: 8 }}>
        <If when={error()}><T size={12} color={c().red}>{error()}</T></If>
      </View>
      <If when={isMac}><View style={{ alignItems: "center", marginTop: 14, gap: 6 }}>
        <Icon name="finger" size={28} tint="#d4495e" />
        <Btn label="使用 Touch ID 解锁" disabled={!touchEnabled || busy()} onPress={touchUnlock} />
        <If when={!touchEnabled}><T size={12} color={c().muted}>解锁后可在安全设置中启用 Touch ID</T></If>
      </View></If>
      <Btn label="忘记主密码？使用恢复密钥" disabled={busy()} onPress={askRecoveryReset} />
      <T size={11} color={c().muted} align="center" style={{ marginTop: 30 }}>磁盘上的资料始终加密 · 数据目录：{vaultDirectory}</T>
    </Centered>
  );
}

const step = signal<0 | 1>(0);
const first = signal("");
const second = signal("");
const createError = signal("");
const creating = signal(false);
/** Chosen "restore from encrypted backup": create the vault, then import the backup into it. */
const restoreAfterCreate = signal(false);

export function OnboardingScreen() {
  const showFirst = signal(false);
  const showSecond = signal(false);
  const error = createError;
  const busy = creating;
  const problem = () =>
    first() && first().length < 10 ? "至少需要 10 个字符。" : second() && first() !== second() ? "两次输入的主密码不一致。" : "";
  const ready = () => first().length >= 10 && first() === second() && !busy();
  const submit = async () => {
    if (!ready()) return;
    busy.set(true);
    try {
      const password = first();
      await create(password);
      first.set("");
      second.set("");
      let offer = false;
      try { offer = shouldOfferBiometrics({ mac: isMac, available: biometricAvailability(), enabled: biometricEnabled(), restoring: restoreAfterCreate() }); } catch { /* Settings still offers it. */ }
      if (offer) offerBiometricsAfterCreate(password);
      if (restoreAfterCreate()) {
        restoreAfterCreate.set(false);
        void importBackup();
      }
    } catch (e) {
      error.set(errorText(e));
    } finally {
      busy.set(false);
    }
  };
  return (
    <Centered width={560}>
      <If when={step() === 0} else={
        <View style={{ gap: 12 }}>
          <T size={24} weight="600">{restoreAfterCreate() ? "为恢复设置新的主密码" : "设置主密码"}</T>
          <T color={c().muted}>{restoreAfterCreate()
            ? "先创建新的密码库，随后选择加密备份文件，并输入创建备份时使用的密码；备份内容会合并进这个新密码库。"
            : "主密码用于加密整个密码库。我们无法帮你找回，请务必记住。"}</T>
          <T size={12} color={c().ink2} style={{ marginTop: 8 }}>主密码</T>
          <Row gap={8}>
            <View style={{ flex: 1 }}>
              <TextBox testID="create-password" value={first()} onChange={(v) => first.set(v)} masked={!showFirst()} autoFocus placeholder="至少 10 个字符" />
            </View>
            <IconBtn icon="eye" label={showFirst() ? "隐藏主密码" : "显示主密码"} tint={showFirst() ? c().blue : c().muted} onPress={() => showFirst.update((s) => !s)} />
          </Row>
          <If when={first()}><Strength level={strengthOf(first())} /></If>
          <T size={12} color={c().ink2} style={{ marginTop: 4 }}>确认主密码</T>
          <Row gap={8}>
            <View style={{ flex: 1 }}>
              <TextBox testID="create-confirm" value={second()} onChange={(v) => second.set(v)} masked={!showSecond()} placeholder="再次输入" onSubmit={submit} />
            </View>
            <IconBtn icon="eye" label={showSecond() ? "隐藏确认密码" : "显示确认密码"} tint={showSecond() ? c().blue : c().muted} onPress={() => showSecond.update((s) => !s)} />
          </Row>
          <T size={12} color={c().red}>{problem() || error()}</T>
          <Banner tone="warn" title="建议使用 4 个以上随机单词组成的短语">例如「海港-枫叶-安静-银色」。</Banner>
          <Row style={{ justifyContent: "space-between" }}>
            <Btn label="返回" onPress={() => { restoreAfterCreate.set(false); step.set(0); }} />
            <Btn label={busy() ? "正在创建…" : "创建密码库"} kind="primary" disabled={!ready()} onPress={submit} />
          </Row>
        </View>
      }>
        <View style={{ gap: 12 }}>
          <Logo size={56} />
          <T size={26} weight="600" style={{ marginTop: 8 }}>欢迎使用 PasswordVault</T>
          <T color={c().muted}>密码、验证码、钱包和笔记全部在本机加密保存。</T>
          <Choice icon="plus" title="创建新的密码库" text="设置主密码，从空白开始" onPress={() => { restoreAfterCreate.set(false); step.set(1); }} recommended />
          <Choice icon="archive" title="从加密备份恢复" text="设置新的主密码后，选择备份文件合并恢复" onPress={() => { restoreAfterCreate.set(true); step.set(1); }} />
          <Choice icon="key" title="使用应急备份与恢复密钥" text="选择完整应急备份，恢复为新密码库" onPress={askEmergencyRestore} />
          <T size={11} color={c().muted} style={{ marginTop: 10 }}>此预览版使用独立数据目录：{vaultDirectory}</T>
        </View>
      </If>
    </Centered>
  );
}

function Choice(props: { icon: any; title: string; text: string; onPress?: () => void; recommended?: boolean; disabled?: boolean }) {
  return (
    <View role="button" accessibilityLabel={props.title} onPress={props.disabled ? undefined : props.onPress}
      style={{ flexDirection: "row", alignItems: "center", gap: 14, padding: 16, borderRadius: 12, borderWidth: props.recommended ? 2 : 1, borderColor: props.recommended ? c().blue : c().line, backgroundColor: c().surface, opacity: props.disabled ? 0.5 : 1, cursor: props.disabled ? "default" : "pointer" }}
      hoverStyle={props.disabled ? undefined : { borderColor: c().blue }}>
      <View style={{ width: 36, height: 36, borderRadius: 9, borderWidth: 1, borderColor: c().line, alignItems: "center", justifyContent: "center" }}>
        <Icon name={props.icon} size={18} tint={c().ink2} />
      </View>
      <View style={{ flex: 1, gap: 3 }}>
        <T size={14} weight="600">{props.title}</T>
        <T size={12} color={c().muted}>{props.text}</T>
      </View>
      <Icon name="chev" size={16} tint={c().faint} />
    </View>
  );
}
