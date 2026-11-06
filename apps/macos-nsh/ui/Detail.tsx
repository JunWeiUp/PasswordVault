// The right column: toolbar and the selected item's details.
import { type JSX, Scroll, signal, View } from "nsh";
import { Menu } from "nsh/desktop";
import { Input } from "nsh/base";
import { Icon } from "./icons";
import {
  Banner, Btn, copySecret, Empty, Field, Group, IconBtn, openSite, Row, SectionHead, Strength, strengthOf, T,
} from "./kit";
import {
  audit, DEST_NAME, dest, edit, editing, flush, lock, noteCategories, restore, saveError, saveState,
  selected, toggleFavorite, type Item,
} from "./store";
import { askDeleteForever, askTrash, showPasswordHistory } from "./sheets";
import { moveToCategoryMenu, rowMenu, Tile } from "./ItemList";
import { c, layout, MONO, fs } from "./theme";
import { formatCode, secondsLeft, useCode } from "./totp";
import { askGeneratedPassword } from "./Tools";
import { RichNoteEditor } from "./notes/RichNoteEditor";
import { openItemHistory } from "./history";
import { DeviceDetail } from "./devices";
import { AccountDetail } from "./entries/AccountDetail";
import { CodeDetail } from "./entries/CodeDetail";
import { openSettings } from "./Settings";
import { vaultInstance } from "./store";

const noteMode = signal<"edit" | "preview">("edit");

function Toolbar(props: { item: Item; extra?: JSX.Element }) {
  const item = () => props.item;
  return (
    <View desktop={{ windowDrag: true }} style={{ height: layout.toolbar, flexDirection: "row", alignItems: "center", paddingLeft: 26, paddingRight: 18, gap: 10, borderBottomWidth: 1, borderBottomColor: c().line }}>
      <Row gap={6} style={{ flex: 1, minWidth: 0 }}>
        <T size={12} color={c().muted}>{DEST_NAME[dest()]}</T>
        <If when={item().type === "secureNote" && item().category}>
          <Icon name="chev" size={11} tint={c().faint} />
          <T size={12} color={c().muted}>{item().category}</T>
        </If>
        <Icon name="chev" size={11} tint={c().faint} />
        <T size={12} weight="500" lines={1} style={{ flexShrink: 1 }}>{item().title || "未命名"}</T>
      </Row>
      <View desktop={{ windowDrag: false }} style={{ flexDirection: "row", alignItems: "center", gap: 6 }}>
        <If when={item().isDeleted} else={
          <>
            <IconBtn icon="star" label={item().isFavorite ? "取消收藏" : "收藏"} fill={item().isFavorite} tint={item().isFavorite ? "#e3a008" : undefined} onPress={() => toggleFavorite(item())} />
            {props.extra}
            <IconBtn icon="more" label="更多操作" onPress={() => void Menu.popup(moreMenu(item()))} />
          </>
        }>
          <Btn testID="restore" label="恢复" icon="history" onPress={() => void restore(item())} />
          <Btn label="永久删除…" kind="danger" onPress={() => askDeleteForever(item())} />
        </If>
        <View style={{ width: 1, height: 20, backgroundColor: c().line, marginHorizontal: 4 }} />
        <Btn label="锁定" icon="lock" kind="ghost" tooltip="⌘L" onPress={() => void lock()} />
      </View>
    </View>
  );
}

function moreMenu(item: Item) {
  return [
    ...(item.type === "password" ? [{ label: "生成新密码…", onSelect: () => askGeneratedPassword(item) }] : []),
    ...(item.passwordHistory?.length ? [{ label: "密码历史…", onSelect: () => showPasswordHistory(item) }] : []),
    { label: "版本历史…", onSelect: () => openItemHistory(item) },
    { label: "复制条目链接", onSelect: () => copySecret(`passwordvault://item/${item.id}`, "条目链接") },
    { type: "separator" as const },
    ...rowMenu(item).filter((m: any) => m.label === "置顶" || m.label === "取消置顶"),
    { label: "移到回收站…", shortcut: "mod+backspace", onSelect: () => askTrash(item) },
  ];
}

function SaveStatus(props: { item: Item }) {
  return (
    <Row gap={6} style={{ justifyContent: "flex-end", minHeight: 22, marginBottom: 4 }}>
      <If when={!props.item.isDeleted} else={<T size={11.5} color={c().muted}>只读 · 已移到回收站</T>}>
        <If when={saveState() === "failed"} else={
          <>
            <Icon name={saveState() === "saving" ? "sync" : "check"} size={12} tint={saveState() === "saving" ? c().muted : c().green} />
            <T size={11.5} color={c().muted}>{saveState() === "saving" ? "正在加密保存…" : "已加密保存"}</T>
          </>
        }>
          <Icon name="alert" size={12} tint={c().red} />
          <T size={11.5} color={c().red}>保存失败：{saveError()}修改仍保留在窗口中。</T>
          <Btn label="重试" onPress={() => void flush()} />
        </If>
      </If>
    </Row>
  );
}

function EditButton() {
  return (
    <Btn label={editing() ? "完成" : "编辑"} icon={editing() ? "check" : "edit"} kind={editing() ? "primary" : "default"}
      tooltip="⌘E" onPress={() => { editing.update((e) => !e); if (!editing()) void flush(); }} />
  );
}

function Hero(props: { item: Item; sub: string }) {
  const item = () => props.item;
  const canEdit = () => editing() && !item().isDeleted;
  return (
    <Row gap={16} style={{ marginBottom: 20 }}>
      <Tile item={item()} size={60} />
      <View style={{ flex: 1, minWidth: 0, gap: 4 }}>
        <If when={canEdit()} else={<T size={26} weight="600" lines={2} selectable>{item().title || "未命名"}</T>}>
          <Input value={item().title} accessibilityLabel="标题" placeholder="标题" onChange={({ value }) => edit(item().id, (d) => (d.title = value))}
            style={{ fontSize: fs(20), fontWeight: "600", paddingHorizontal: 8, paddingVertical: 4, borderRadius: 6, borderWidth: 1, borderColor: c().line, color: c().ink, backgroundColor: c().surface }} />
        </If>
        <T size={12} color={c().muted} lines={1}>{props.sub}</T>
      </View>
    </Row>
  );
}

const field = (item: Item, key: string) => (v: string) => edit(item.id, (d) => (d[key] = v));

function NoteBlock(props: { item: Item }) {
  const item = () => props.item;
  return (
    <>
      <SectionHead title="备注" />
      <If when={editing() && !item().isDeleted} else={
        item().note ? <View style={{ borderLeftWidth: 2, borderLeftColor: c().blueLine, paddingLeft: 14 }}><T size={12.5} color={c().ink2} selectable>{item().note}</T></View> : <T size={11.5} color={c().muted}>没有备注。</T>
      }>
        <Input multiline value={item().note ?? ""} accessibilityLabel="备注" onChange={({ value }) => edit(item().id, (d) => (d.note = value))}
          style={{ minHeight: 80, fontSize: fs(13), padding: 8, borderRadius: 7, borderWidth: 1, borderColor: c().line, color: c().ink, backgroundColor: c().surface }} />
      </If>
    </>
  );
}

function Meta(props: { item: Item }) {
  const item = () => props.item;
  return (
    <>
      <SectionHead title="记录" />
      <Group>
        <Field label="分类" value={item().category ?? ""} editing={editing()} onChange={field(item(), "category")} nocopy />
        <Field label="标签" value={(item().tags ?? []).join("、")} editing={editing()} nocopy placeholder="用顿号分隔"
          onChange={(v) => edit(item().id, (d) => (d.tags = v.split(/[、,，]/).map((s) => s.trim()).filter(Boolean)))} />
        <Field label="修改时间" value={item().updatedAt ? new Date(item().updatedAt).toLocaleString() : ""} nocopy />
        <If when={item().type === "password"}>
          <Field label="密码历史" value={item().passwordHistory?.length ? `${item().passwordHistory.length} 个旧密码` : "暂无"} nocopy
            actions={item().passwordHistory?.length ? <Btn kind="ghost" label="查看" onPress={() => showPasswordHistory(item())} /> : undefined} />
        </If>
      </Group>
    </>
  );
}

const nested = (item: Item, group: "card" | "identity", key: string) => (v: string) =>
  edit(item.id, (d) => {
    d[group] = { ...(d[group] ?? {}), [key]: v };
  });

function WalletDetail(props: { item: Item }) {
  const item = () => props.item;
  const card = () => item().card ?? {};
  const id = () => item().identity ?? {};
  const words = signal(false);
  if (item().type === "creditCard") {
    return (
      <>
        <Hero item={item()} sub={[card().brand, card().cardholder].filter(Boolean).join(" · ") || "银行卡"} />
        <View style={{ width: 340, height: 196, borderRadius: 16, backgroundColor: "#1f2d4a", padding: 22, justifyContent: "space-between", marginBottom: 20 }}>
          <Row style={{ justifyContent: "space-between" }}><T weight="600" color="#e9eef8">{item().title}</T><T size={12} color="#e9eef8">{card().brand ?? ""}</T></Row>
          <View style={{ width: 38, height: 28, borderRadius: 5, backgroundColor: "#c9b27a" }} />
          <T mono size={19} color="#e9eef8">•••• •••• •••• {String(card().number ?? "").slice(-4) || "····"}</T>
          <Row style={{ justifyContent: "space-between" }}><T size={11} color="#cfd8ea">{card().cardholder ?? ""}</T><T size={11} color="#cfd8ea">有效期 {card().expiryMonth ?? "--"}/{card().expiryYear ?? "--"}</T></Row>
        </View>
        <Row gap={8} style={{ marginBottom: 6 }}>
          <Btn label="复制卡号" icon="copy" kind="primary" disabled={!card().number} onPress={() => copySecret(String(card().number ?? "").replace(/\s/g, ""), "卡号")} />
          <Btn label="复制安全码" disabled={!card().securityCode} onPress={() => copySecret(card().securityCode, "安全码")} />
        </Row>
        <SectionHead title="银行卡信息" />
        <Group>
          <Field label="持卡人" value={card().cardholder ?? ""} editing={editing()} onChange={nested(item(), "card", "cardholder")} />
          <Field label="卡号" value={card().number ?? ""} secret editing={editing()} onChange={nested(item(), "card", "number")} />
          <Field label="有效期（月）" value={card().expiryMonth ?? ""} editing={editing()} onChange={nested(item(), "card", "expiryMonth")} placeholder="MM" />
          <Field label="有效期（年）" value={card().expiryYear ?? ""} editing={editing()} onChange={nested(item(), "card", "expiryYear")} placeholder="YYYY" />
          <Field label="安全码" value={card().securityCode ?? ""} secret editing={editing()} onChange={nested(item(), "card", "securityCode")} />
          <Field label="卡组织" value={card().brand ?? ""} editing={editing()} onChange={nested(item(), "card", "brand")} placeholder="Visa、银联…" />
        </Group>
        <NoteBlock item={item()} />
        <Meta item={item()} />
      </>
    );
  }
  if (item().type === "identity") {
    const f = (label: string, key: string, secret = false) => <Field label={label} value={id()[key] ?? ""} secret={secret} editing={editing()} onChange={nested(item(), "identity", key)} />;
    return (
      <>
        <Hero item={item()} sub="身份信息" />
        <SectionHead title="个人信息" />
        <Group>{f("姓", "lastName")}{f("名", "firstName")}{f("邮箱", "email")}{f("电话", "phone")}{f("公司", "company")}</Group>
        <SectionHead title="地址" />
        <Group>{f("地址 1", "address1")}{f("地址 2", "address2")}{f("城市", "city")}{f("省/州", "region")}{f("邮编", "postalCode")}{f("国家/地区", "country")}</Group>
        <NoteBlock item={item()} />
        <Meta item={item()} />
      </>
    );
  }
  return (
    <>
      <Hero item={item()} sub={item().network ?? "加密货币钱包"} />
      <Row gap={8} style={{ marginBottom: 6 }}>
        <Btn label="复制地址" icon="copy" kind="primary" disabled={!item().address} onPress={() => copySecret(item().address, "收款地址")} />
      </Row>
      <SectionHead title="钱包信息" />
      <Group>
        <Field label="网络" value={item().network ?? ""} editing={editing()} onChange={field(item(), "network")} />
        <Field label="收款地址" value={item().address ?? ""} mono editing={editing()} onChange={field(item(), "address")} />
        <Field label="私钥" value={item().privateKey ?? ""} secret nocopy editing={editing()} onChange={field(item(), "privateKey")} />
      </Group>
      <SectionHead title="助记词" note="默认隐藏；不提供复制" right={!editing() && item().mnemonic ? <Btn label={words() ? "隐藏" : "显示助记词"} icon="eye" onPress={() => words.update((w) => !w)} /> : undefined} />
      <If when={editing()} else={
        <If when={item().mnemonic} else={<T size={11.5} color={c().muted}>未保存助记词。</T>}>
          <View style={{ flexDirection: "row", flexWrap: "wrap", gap: 8 }}>
            {String(item().mnemonic).trim().split(/\s+/).map((w, i) => (
              <View style={{ width: "23%", flexDirection: "row", gap: 8, borderWidth: 1, borderColor: c().line, borderRadius: 7, paddingHorizontal: 10, paddingVertical: 8 }}>
                <T mono size={12} color={c().faint}>{i + 1}</T>
                <T mono size={12.5}>{words() ? w : "•••••"}</T>
              </View>
            ))}
          </View>
        </If>
      }>
        <Input multiline masked value={item().mnemonic ?? ""} accessibilityLabel="助记词" onChange={({ value }) => field(item(), "mnemonic")(value)}
          style={{ minHeight: 70, fontFamily: MONO, fontSize: fs(12.5), padding: 8, borderRadius: 7, borderWidth: 1, borderColor: c().line, color: c().ink, backgroundColor: c().surface }} />
      </If>
      <NoteBlock item={item()} />
      <Meta item={item()} />
    </>
  );
}

function NoteDetail(props: { item: Item }) {
  const item = () => props.item;
  const rich = () => item().noteFormat === "rich-v1";
  const canEdit = () => noteMode() === "edit" && !item().isDeleted;
  const extra = (
    <If when={!item().isDeleted}>
      <View style={{ flexDirection: "row", backgroundColor: c().field, borderRadius: 7, padding: 2 }}>
        {(["edit", "preview"] as const).map((m) => (
          <View role="button" accessibilityState={{ selected: noteMode() === m }} onPress={() => noteMode.set(m)}
            style={{ paddingHorizontal: 12, paddingVertical: 4, borderRadius: 5, backgroundColor: noteMode() === m ? c().surface : "transparent", cursor: "pointer" }}>
            <T size={12} weight={noteMode() === m ? "600" : "400"} color={noteMode() === m ? c().blue : c().muted}>{m === "edit" ? "编辑" : "预览"}</T>
          </View>
        ))}
      </View>
    </If>
  );
  return (
    <>
      <Toolbar item={item()} extra={extra} />
      <Scroll style={{ flex: 1 }} contentStyle={{ paddingHorizontal: 40, paddingTop: 18, paddingBottom: 40 }}>
        <View style={{ maxWidth: 760 }}>
          <SaveStatus item={item()} />
          <If when={item().isDeleted}>
            <Banner tone="info" title="已移到回收站" actions={<Btn label="恢复" onPress={() => void restore(item())} />}>
              恢复后回到原分类{item().category ? `「${item().category}」` : ""}。
            </Banner>
          </If>
          <If when={canEdit()} else={<T size={30} weight="700" selectable>{item().title || "未命名笔记"}</T>}>
            <Input value={item().title} accessibilityLabel="标题" placeholder="标题" onChange={({ value }) => edit(item().id, (d) => (d.title = value))}
              style={{ fontSize: fs(30), fontWeight: "700", color: c().ink, backgroundColor: "transparent", borderWidth: 0, paddingVertical: 4 }} />
          </If>
          <Row gap={8} style={{ marginVertical: 10 }}>
            <Icon name="folder" size={12} tint={c().faint} />
            <If when={!item().isDeleted} else={<T size={12} color={c().muted}>{item().category || "未分类"}</T>}>
              <View role="button" accessibilityLabel="移动到分类" tooltip="移动到分类" onPress={() => void Menu.popup(moveToCategoryMenu(item()))}
                style={{ flexDirection: "row", alignItems: "center", gap: 4, cursor: "pointer" }}>
                <T size={12} color={c().blue}>{item().category || "未分类"}</T>
                <Icon name="chevd" size={11} tint={c().blue} />
              </View>
            </If>
          </Row>
          <View style={{ height: 1, backgroundColor: c().line, marginBottom: 16 }} />
          <If when={!item().noteSummary} else={<T size={13} color={c().muted}>正在加载笔记…</T>}>
            <RichNoteEditor item={item() as any} editable={canEdit()} vault={vaultInstance}
              onChange={(patch, owner) => edit(owner ?? item().id, (d) => Object.assign(d, patch))} />
          </If>

        </View>
      </Scroll>
      <View testID="note-status-footer" style={{ flexShrink: 0, paddingHorizontal: 40, paddingVertical: 12, borderTopWidth: 1, borderTopColor: c().line, backgroundColor: c().surface }}>
        <Row style={{ maxWidth: 760, justifyContent: "space-between" }}>
          <T size={11} color={c().faint}>{String(item().note ?? "").length} 字</T>
          <T size={11} color={c().faint}>{canEdit() ? "自动加密保存 · ⌘Z 撤销" : "预览为只读"}</T>
        </Row>
      </View>
    </>
  );
}

function ItemView(props: { item: Item }) {
  if (props.item.type === "secureNote") return <NoteDetail item={props.item} />;
  const body =
    props.item.type === "password" ? <AccountDetail item={props.item} editing={editing() && !props.item.isDeleted} />
    : props.item.type === "totp" ? <CodeDetail item={props.item} editing={editing() && !props.item.isDeleted} />
    : props.item.type === "device" ? <DeviceDetail item={props.item} editable={editing() && !props.item.isDeleted} onOpenSettings={() => openSettings("ai")} />
    : <WalletDetail item={props.item} />;
  return (
    <>
      <Toolbar item={props.item} extra={<If when={!props.item.isDeleted}><EditButton /></If>} />
      <Scroll style={{ flex: 1 }} contentStyle={{ paddingHorizontal: 40, paddingTop: 18, paddingBottom: 40 }}>
        <View style={{ maxWidth: props.item.type === "device" ? undefined : 860 }}>
          <SaveStatus item={props.item} />
          <If when={props.item.isDeleted}>
            <Banner tone="info" title="已移到回收站" actions={<Btn label="恢复" onPress={() => void restore(props.item)} />}>恢复后回到原来的位置并保留全部字段。</Banner>
          </If>
          {body}
        </View>
      </Scroll>
    </>
  );
}

export function Detail() {
  return (
    <View testID="detail" style={{ flex: 1, minWidth: 0, backgroundColor: c().surface }}>
      <If when={selected()} else={
        <>
          <View desktop={{ windowDrag: true }} style={{ height: layout.toolbar, borderBottomWidth: 1, borderBottomColor: c().line }} />
          <View style={{ flex: 1, justifyContent: "center" }}><Empty icon="paper" title="选择一个项目" text="从左侧列表选择，或按 ⌘N 新建。" /></View>
        </>
      }>
        <Each of={selected() ? [selected()!] : []} key={(i) => `${i.id}:${i.type}`}>
          {(item) => <ItemView item={item()} />}
        </Each>
      </If>
    </View>
  );
}
