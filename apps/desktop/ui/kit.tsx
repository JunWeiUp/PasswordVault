// Shared controls: buttons, field rows, banners, sheets and copy-with-clear.
import { Clipboard, type JSX, signal, Text, View } from "nsh";
import { Dialog, Input, Switch } from "nsh/base";
import { Icon, type IconName } from "./icons";
import { toast } from "./store";
import { c, MONO, radius, fs } from "./theme";

export function T(props: {
  children?: any; size?: number; weight?: "400" | "500" | "600" | "700"; color?: string;
  mono?: boolean; lines?: number; selectable?: boolean; style?: any; align?: "left" | "center" | "right";
}) {
  return (
    <Text
      style={{
        numberOfLines: props.lines, userSelect: props.selectable ? "text" : undefined,
        fontSize: fs(props.size ?? 13),
        fontWeight: props.weight ?? "400",
        color: props.color ?? c().ink,
        fontFamily: props.mono ? MONO : undefined,
        textAlign: props.align,
        ...props.style,
      }}
    >
      {props.children}
    </Text>
  );
}

type Kind = "primary" | "default" | "ghost" | "danger" | "dangerSolid";
export function Btn(props: {
  label: string; icon?: IconName; kind?: Kind; onPress?: () => void; disabled?: boolean;
  tooltip?: string; hint?: string; grow?: boolean; testID?: string;
}) {
  const kind = () => props.kind ?? "default";
  const bg = () =>
    ({ primary: c().blue, default: c().surface, ghost: "transparent", danger: c().surface, dangerSolid: c().red })[kind()];
  const fg = () =>
    ({ primary: c().onBlue, default: c().ink, ghost: c().ink2, danger: c().red, dangerSolid: c().onBlue })[kind()];
  return (
    <View
      role="button"
      testID={props.testID}
      accessibilityLabel={props.label}
      accessibilityState={{ disabled: !!props.disabled }}
      tooltip={props.tooltip}
      onPress={props.disabled ? undefined : props.onPress}
      style={{
        flexDirection: "row", alignItems: "center", justifyContent: "center", gap: 6,
        paddingHorizontal: 12, height: fs(30), borderRadius: radius.control,
        borderWidth: kind() === "ghost" ? 0 : 1,
        borderColor: kind() === "primary" ? c().blue : kind() === "dangerSolid" ? c().red : c().line,
        backgroundColor: bg(), opacity: props.disabled ? 0.45 : 1, cursor: props.disabled ? "default" : "pointer",
        flexGrow: props.grow ? 1 : 0,
      }}
      hoverStyle={props.disabled ? undefined : { backgroundColor: kind() === "primary" ? c().blueHover : kind() === "dangerSolid" ? c().red : c().blueSoft }}
      activeStyle={{ opacity: 0.8 }}
      focusStyle={{ borderColor: c().blue, borderWidth: 2 }}
    >
      {props.icon && <Icon name={props.icon} size={14} tint={fg()} />}
      <T size={12.5} weight={kind() === "primary" ? "600" : "500"} color={fg()}>{props.label}</T>
      {props.hint && <T size={11} color={kind() === "primary" ? "rgba(255,255,255,0.75)" : c().faint}>{props.hint}</T>}
    </View>
  );
}

export function IconBtn(props: { icon: IconName; label: string; onPress?: (e?: any) => void; tint?: string; fill?: boolean; size?: number; disabled?: boolean }) {
  return (
    <View
      role="button"
      accessibilityLabel={props.label}
      tooltip={props.label}
      onPress={props.disabled ? undefined : props.onPress}
      style={{ padding: 5, borderRadius: 6, cursor: "pointer", opacity: props.disabled ? 0.4 : 1 }}
      hoverStyle={{ backgroundColor: c().field }}
      activeStyle={{ opacity: 0.7 }}
    >
      <Icon name={props.icon} size={props.size ?? 16} tint={props.tint ?? c().muted} fill={props.fill} />
    </View>
  );
}

export function Row(props: { children?: any; gap?: number; style?: any; wrap?: boolean }) {
  return <View style={{ flexDirection: "row", alignItems: "center", gap: props.gap ?? 8, flexWrap: props.wrap ? "wrap" : "nowrap", ...props.style }}>{props.children}</View>;
}
export const Spacer = () => <View style={{ flex: 1 }} />;

export function SectionHead(props: { title: string; note?: string; right?: JSX.Element }) {
  return (
    <Row style={{ marginTop: 22, marginBottom: 8, justifyContent: "space-between" }}>
      <T size={12.5} weight="600">{props.title}</T>
      <Row gap={8}>
        {props.note && <T size={11} color={c().muted}>{props.note}</T>}
        {props.right}
      </Row>
    </Row>
  );
}

export function Group(props: { children?: any; style?: any }) {
  return (
    <View style={{ borderWidth: 1, borderColor: c().line, borderRadius: radius.card, paddingHorizontal: 14, backgroundColor: c().surface, ...props.style }}>
      {props.children}
    </View>
  );
}

const CLEAR_AFTER_MS = 30_000;
/** Copies `value`; clears the clipboard after 30 s if it still holds this value. */
export async function copySecret(value: string, label: string) {
  if (!value) return;
  try {
    await Clipboard.writeText(value);
    toast(`已复制${label} · 30 秒后清除`);
    setTimeout(async () => {
      try {
        if ((await Clipboard.readText()) === value) await Clipboard.writeText("");
      } catch {}
    }, CLEAR_AFTER_MS);
  } catch {
    toast("无法写入剪贴板");
  }
}

/** One labelled value: copy, reveal for secrets, open for links, or an input while editing. */
export function Field(props: {
  label: string; value: string; secret?: boolean; mono?: boolean; link?: boolean; nocopy?: boolean;
  editing?: boolean; onChange?: (v: string) => void; placeholder?: string; after?: JSX.Element;
  actions?: JSX.Element; multiline?: boolean;
}) {
  const shown = signal(false);
  const editable = () => props.editing && props.onChange;
  return (
    <View style={{ flexDirection: "row", alignItems: props.multiline ? "flex-start" : "center", gap: 14, paddingVertical: 10, minHeight: 46, borderBottomWidth: 1, borderBottomColor: c().line2 }}>
      <T size={12} color={c().muted} style={{ width: 96, paddingTop: props.multiline ? 6 : 0 }}>{props.label}</T>
      <View style={{ flex: 1, minWidth: 0 }}>
        <If when={editable()} else={
          <T selectable={!props.secret || shown()} mono={props.mono || props.secret} size={props.mono || props.secret ? 12.5 : 13} color={props.value ? c().ink : c().faint}>
            {props.value ? (props.secret && !shown() ? "••••••••••••" : props.value) : "未填写"}
          </T>
        }>
          <Input
            value={props.value}
            masked={props.secret && !shown()}
            multiline={props.multiline}
            placeholder={props.placeholder ?? props.label}
            accessibilityLabel={props.label}
            autoCorrect={false}
            onChange={({ value }) => props.onChange?.(value)}
            style={{ fontSize: fs(13), paddingHorizontal: 8, paddingVertical: 5, borderRadius: 6, borderWidth: 1, borderColor: c().line, backgroundColor: c().surface, color: c().ink, fontFamily: props.mono || props.secret ? MONO : undefined, minHeight: props.multiline ? 70 : undefined }}
          />
        </If>
        {props.after}
      </View>
      <Row gap={2}>
        {props.actions}
        <If when={props.secret}>
          <SmallAction icon="eye" label={shown() ? "隐藏" : "显示"} onPress={() => shown.update((s) => !s)} />
        </If>
        <If when={props.link && props.value && !props.editing}>
          <SmallAction icon="globe" label="打开" onPress={() => openSite(props.value)} />
        </If>
        <If when={!props.nocopy && props.value && !props.editing}>
          <SmallAction icon="copy" label="复制" onPress={() => copySecret(props.value, props.label)} />
        </If>
      </Row>
    </View>
  );
}

export function SmallAction(props: { icon?: IconName; label: string; onPress: () => void; tint?: string }) {
  return (
    <View role="button" accessibilityLabel={props.label} onPress={props.onPress}
      style={{ flexDirection: "row", alignItems: "center", gap: 4, paddingHorizontal: 7, paddingVertical: 3, borderRadius: 5, cursor: "pointer" }}
      hoverStyle={{ backgroundColor: c().field }}>
      {props.icon && <Icon name={props.icon} size={12} tint={props.tint ?? c().muted} />}
      <T size={11.5} color={props.tint ?? c().muted}>{props.label}</T>
    </View>
  );
}

export async function openSite(value: string) {
  const { openUrl } = await import("nsh");
  const url = /^https?:\/\//i.test(value) ? value : `https://${value}`;
  try {
    if (!url.toLowerCase().startsWith("https://")) return toast("只允许打开 HTTPS 网站");
    await openUrl(url);
  } catch {
    toast("无法打开该网址");
  }
}

export function Pill(props: { children: any; tone?: "blue" | "green" | "orange" | "red" | "gray" }) {
  const tone = () => props.tone ?? "gray";
  const bg = () => ({ blue: c().blueSoft, green: c().greenSoft, orange: c().orangeSoft, red: c().redSoft, gray: c().soft })[tone()];
  const fg = () => ({ blue: c().blue, green: c().green, orange: c().orange, red: c().red, gray: c().ink2 })[tone()];
  return (
    <View style={{ backgroundColor: bg(), borderRadius: 20, paddingHorizontal: 8, paddingVertical: 2 }}>
      <T size={11} color={fg()}>{props.children}</T>
    </View>
  );
}

export function Banner(props: { tone: "warn" | "info" | "ok" | "err"; icon?: IconName; title: string; children?: any; actions?: JSX.Element }) {
  const fg = () => ({ warn: c().orange, info: c().blue, ok: c().green, err: c().red })[props.tone];
  const bg = () => ({ warn: c().orangeSoft, info: c().blueSoft, ok: c().greenSoft, err: c().redSoft })[props.tone];
  return (
    <View role={props.tone === "err" ? "alert" : undefined} style={{ flexDirection: "row", gap: 10, alignItems: "flex-start", padding: 12, borderRadius: radius.row, backgroundColor: bg(), marginBottom: 16 }}>
      <Icon name={props.icon ?? (props.tone === "info" ? "info" : props.tone === "ok" ? "check" : "alert")} size={16} tint={fg()} />
      <View style={{ flex: 1, gap: 2 }}>
        <T size={12.5} weight="600" color={fg()}>{props.title}</T>
        {props.children && <T size={12} color={fg()}>{props.children}</T>}
      </View>
      {props.actions && <Row gap={6}>{props.actions}</Row>}
    </View>
  );
}

export function Toggle(props: { title: string; note?: string; checked: boolean; onChange: (v: boolean) => void; disabled?: boolean }) {
  return (
    <Row style={{ paddingVertical: 11, borderBottomWidth: 1, borderBottomColor: c().line2, gap: 14 }}>
      <View style={{ flex: 1, gap: 2 }}>
        <T size={13}>{props.title}</T>
        {props.note && <T size={11} color={c().muted}>{props.note}</T>}
      </View>
      <Switch
        checked={props.checked}
        disabled={props.disabled}
        accessibilityLabel={props.title}
        onChange={({ checked }) => props.onChange(checked)}
        trackStyle={{ width: 32, height: 19, borderRadius: 10, padding: 2, backgroundColor: props.checked ? c().blue : c().line }}
        thumbStyle={{ width: 15, height: 15, borderRadius: 8, backgroundColor: "#ffffff", transform: [{ translateX: props.checked ? 13 : 0 }] }}
      />
    </Row>
  );
}

export function OptionRow(props: { title: string; note?: string; children: any }) {
  return (
    <Row style={{ paddingVertical: 11, borderBottomWidth: 1, borderBottomColor: c().line2, gap: 14 }}>
      <View style={{ flex: 1, gap: 2 }}>
        <T size={13}>{props.title}</T>
        {props.note && <T size={11} color={c().muted}>{props.note}</T>}
      </View>
      {props.children}
    </Row>
  );
}

// --- Sheets ----------------------------------------------------------------

type SheetSpec = { width?: number; render: (close: () => void) => JSX.Element };
const sheet = signal<SheetSpec | null>(null);
export const openSheet = (spec: SheetSpec) => sheet.set(spec);
export const closeSheet = () => sheet.set(null);
export const sheetOpen = () => sheet() !== null;

/** Hosts the current sheet over the window. */
export function SheetHost() {
  return (
    <If when={sheet()}>
      <Dialog
        open
        animation="fade"
        onOpenChange={({ open: visible }) => !visible && closeSheet()}
        backdropStyle={{ backgroundColor: c().backdrop }}
        style={{
          alignSelf: "center", marginTop: 90, width: sheet()?.width ?? 520, maxHeight: "86%",
          backgroundColor: c().surface, borderRadius: radius.sheet, borderWidth: 1, borderColor: c().line,
          padding: 22, gap: 10, boxShadow: "0 12px 30px rgba(27,42,68,0.25)",
        }}
      >
        {sheet()?.render(closeSheet)}
      </Dialog>
    </If>
  );
}

export function SheetTitle(props: { title: string; text?: string }) {
  return (
    <View style={{ gap: 6 }}>
      <T size={17} weight="600">{props.title}</T>
      {props.text && <T size={12.5} color={c().muted}>{props.text}</T>}
    </View>
  );
}
export function SheetFooter(props: { children: any; left?: JSX.Element }) {
  return (
    <Row style={{ marginTop: 14, justifyContent: "flex-end" }}>
      {props.left}
      <Spacer />
      {props.children}
    </Row>
  );
}

/** A confirmation sheet; resolves once with `onConfirm` when confirmed. */
export function confirm(o: { title: string; text: string; ok: string; danger?: boolean; onConfirm: () => void }) {
  openSheet({
    render: (close) => (
      <View style={{ gap: 6 }}>
        <SheetTitle title={o.title} text={o.text} />
        <SheetFooter>
          <Btn label="取消" onPress={close} />
          <Btn label={o.ok} kind={o.danger ? "dangerSolid" : "primary"} onPress={() => { close(); o.onConfirm(); }} />
        </SheetFooter>
      </View>
    ),
  });
}

export function TextBox(props: { ref?: (r: any) => void; value: string; onChange: (v: string) => void; placeholder?: string; masked?: boolean; autoFocus?: boolean; onSubmit?: () => void; label?: string; mono?: boolean; width?: number; testID?: string }) {
  return (
    <Input
      ref={props.ref}
      testID={props.testID}
      value={props.value}
      masked={props.masked}
      autoFocus={props.autoFocus}
      placeholder={props.placeholder}
      accessibilityLabel={props.label ?? props.placeholder}
      autoCorrect={false}
      onChange={({ value }) => props.onChange(value)}
      // Return can arrive before the last change events on a real window: take the
      // submitted text as the field's value before acting on it.
      onSubmit={(e) => {
        if (typeof e?.text === "string" && e.text !== props.value) props.onChange(e.text);
        props.onSubmit?.();
      }}
      style={{ fontSize: fs(13), paddingHorizontal: 10, paddingVertical: 7, borderRadius: radius.control, borderWidth: 1, borderColor: c().line, backgroundColor: c().surface, color: c().ink, fontFamily: props.mono ? MONO : undefined, width: props.width }}
    />
  );
}

export function Strength(props: { level: number }) {
  const color = () => (props.level <= 1 ? c().red : props.level === 2 ? c().orange : c().green);
  return (
    <Row gap={3} style={{ marginTop: 6 }}>
      {[1, 2, 3, 4].map((i) => (
        <View style={{ width: 26, height: 4, borderRadius: 2, backgroundColor: i <= props.level ? color() : c().line }} />
      ))}
      <T size={10.5} color={c().muted} style={{ marginLeft: 6 }}>{["", "弱", "一般", "良好", "强"][props.level] ?? ""}</T>
    </Row>
  );
}

/** A rough strength level 1–4 from length and character classes (display only). */
export function strengthOf(password: string) {
  if (!password) return 0;
  const classes = [/[a-z]/, /[A-Z]/, /[0-9]/, /[^a-zA-Z0-9]/].filter((r) => r.test(password)).length;
  if (password.length < 10) return 1;
  if (password.length < 12 || classes < 2) return 2;
  if (password.length < 16 || classes < 3) return 3;
  return 4;
}

export function Empty(props: { icon: IconName; title: string; text?: string; action?: JSX.Element }) {
  return (
    <View style={{ alignItems: "center", paddingVertical: 60, paddingHorizontal: 20, gap: 8 }}>
      <View style={{ width: 56, height: 56, borderRadius: 14, backgroundColor: c().soft, alignItems: "center", justifyContent: "center", marginBottom: 6 }}>
        <Icon name={props.icon} size={22} tint={c().faint} />
      </View>
      <T size={14} weight="600">{props.title}</T>
      {props.text && <T size={12} color={c().muted} align="center">{props.text}</T>}
      {props.action && <View style={{ marginTop: 8 }}>{props.action}</View>}
    </View>
  );
}
