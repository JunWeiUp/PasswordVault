// Interactive Paired AI Clients strip and inline expandable management card.
// Shared controls live in `ClientBadges.tsx`; modal sheets live in `ClientSheets.tsx`.
import { View } from "nsh";
import { Menu, type MenuItem } from "nsh/desktop";
import { Icon } from "../icons";
import { Banner, Btn, Card, IconBtn, Pill, Row, Spacer, T, TextBox } from "../kit";
import { c, fs, radius } from "../theme";
import {
  clientStateLabel,
  clientSubline,
  countAiClientStates,
  filterAiClients,
  findDuplicateClientNames,
  formatPairedTime,
  type AiClientFilter,
  type AiClientState,
  type AiClientView,
} from "../api/aiClients";
import {
  FingerprintChip,
  SoftActionBtn,
  StatusDot,
  auditClientId,
  clientFilter,
  clientNotesMap,
  clientSearch,
  expandedClientId,
  revokeClientWithConfirm,
  saveClientNote,
  stateTone,
  toggleAuditFilter,
  togglePauseClient,
} from "./ClientBadges";
import { openCleanupUnusedSheet, openClientsManagerSheet, openEditClientSheet } from "./ClientSheets";

export {
  auditClientId,
  clientFilter,
  clientNotesMap,
  clientSearch,
  expandedClientId,
  openCleanupUnusedSheet,
  openClientsManagerSheet,
  openEditClientSheet,
  revokeClientWithConfirm,
  saveClientNote,
  toggleAuditFilter,
  togglePauseClient,
};

/** Full-width interactive status strip inside the AI Workspace hero card. */
export function HeroClientStrip(props: {
  views: () => AiClientView[];
  writableCount: () => number;
  excludedCount: () => number;
  onManage: () => void;
}) {
  const counts = () => countAiClientStates(props.views());
  const toggleChip = (f: "active" | "paused" | "unused") => {
    clientFilter.set(clientFilter() === f ? "all" : f);
  };
  const chip = (key: "active" | "paused" | "unused", label: string, state: AiClientState) => {
    const on = () => clientFilter() === key;
    return (
      <View
        role="button"
        testID={`ai-hero-chip-${key}`}
        accessibilityLabel={`筛选${label}`}
        onPress={() => toggleChip(key)}
        style={{
          flexDirection: "row",
          alignItems: "center",
          gap: 5,
          paddingHorizontal: 8,
          paddingVertical: 3,
          borderRadius: 99,
          borderWidth: 1,
          borderColor: on() ? c().blue : c().line,
          backgroundColor: on() ? c().blueSoft : c().surface,
          cursor: "pointer",
        }}
        hoverStyle={{ borderColor: c().blueLine, backgroundColor: c().blueSoft }}
      >
        <StatusDot state={state} size={6} />
        <T size={11} weight={on() ? "600" : "400"} color={on() ? c().blue : c().ink2}>{label}</T>
      </View>
    );
  };

  return (
    <Row
      testID="ai-hero-client-strip"
      gap={10}
      wrap
      style={{
        justifyContent: "space-between",
        paddingHorizontal: 12,
        paddingVertical: 9,
        borderRadius: 9,
        borderWidth: 1,
        borderColor: c().line,
        backgroundColor: c().surface,
      }}
    >
      <Row gap={8} wrap style={{ flex: 1, minWidth: 260 }}>
        <View style={{ width: 26, height: 26, borderRadius: 7, backgroundColor: c().blueSoft, alignItems: "center", justifyContent: "center", flexShrink: 0 }}>
          <Icon name="shield" size={14} tint={c().blue} />
        </View>
        <T size={12.5} weight="600">
          {counts().total ? `${counts().total} 个已配对客户端` : "暂无已配对客户端"}
        </T>
        <If when={counts().total > 0} else={<T size={11} color={c().muted}>配对后即可按右侧访问范围直接使用</T>}>
          <Row gap={5} wrap>
            {chip("active", `${counts().active} 活跃`, "active")}
            <If when={counts().paused > 0}>{chip("paused", `${counts().paused} 已暂停`, "paused")}</If>
            <If when={counts().unused > 0}>{chip("unused", `${counts().unused} 未使用`, "unused")}</If>
          </Row>
        </If>
        <T size={11} color={c().muted}>
          {`· ${props.writableCount()} 个 AI 可写目录${props.excludedCount() ? ` · ${props.excludedCount()} 个已隐藏条目` : ""}`}
        </T>
      </Row>
      <Btn testID="ai-open-manager-btn" label="管理客户端…" onPress={props.onManage} />
    </Row>
  );
}

/** Prominent inline expandable paired clients card with filtering, search & cleanup. */
export function PairedClientsCard(props: {
  views: () => AiClientView[];
  scopeSummary: () => string;
  compact: () => boolean;
  onManage: () => void;
}) {
  const counts = () => countAiClientStates(props.views());
  const dups = () => findDuplicateClientNames(props.views());
  const filtered = () => filterAiClients(props.views(), clientFilter(), clientSearch());

  const rowMenu = (v: AiClientView): MenuItem[] => [
    { label: expandedClientId() === v.id ? "收起详情" : "展开详情", onSelect: () => expandedClientId.set(expandedClientId() === v.id ? null : v.id) },
    { label: "编辑名称与备注…", onSelect: () => openEditClientSheet(v) },
    { label: auditClientId() === v.id ? "取消日志筛选" : "只看此客户端日志", onSelect: () => toggleAuditFilter(v) },
    { label: v.paused ? "恢复访问权限" : "暂停访问（保留令牌）", onSelect: () => void togglePauseClient(v) },
    { type: "separator" },
    { label: "撤销此客户端…", onSelect: () => revokeClientWithConfirm(v) },
  ];

  return (
    <View testID="ai-paired-clients-card">
      <Card
        title="已配对客户端"
        note="按右侧「访问范围」生效，仅读取密码等秘密需审批（read 的 field 参数）。点击任意行展开指纹、活跃度与管理项。"
        right={
          <Row gap={6}>
            <Pill tone="blue">{String(counts().total)}</Pill>
            <If when={dups().length > 0}>
              <Pill tone="orange">{`${dups().length} 组同名`}</Pill>
            </If>
            <Btn testID="ai-batch-manage-btn" label="批量管理…" kind="ghost" onPress={props.onManage} />
          </Row>
        }
      >
        <If when={dups().length > 0 || counts().unused > 0}>
          <Row
            gap={8}
            wrap
            style={{
              paddingHorizontal: 10,
              paddingVertical: 8,
              borderRadius: 8,
              backgroundColor: c().orangeSoft,
              borderWidth: 1,
              borderColor: c().orange,
            }}
          >
            <Icon name="alert" size={14} tint={c().orange} />
            <T size={11.5} color={c().orange} style={{ flex: 1, minWidth: 180 }}>
              {`${dups().length ? `检测到同名客户端（${dups().map(([n, k]) => `${n} ×${k}`).join("、")}）` : ""}${dups().length && counts().unused ? "，且有 " : ""}${counts().unused ? `${counts().unused} 个从未调用` : ""}；建议添加备注区分或清理闲置令牌。`}
            </T>
            <If when={counts().unused > 0}>
              <Btn
                testID="ai-cleanup-unused-btn"
                label={`一键清理未使用 (${counts().unused})`}
                onPress={() => openCleanupUnusedSheet(props.views().filter((v) => v.filterKey === "unused"))}
              />
            </If>
          </Row>
        </If>

        <If when={counts().total > 0}>
          <Row gap={8} wrap style={{ justifyContent: "space-between" }}>
            <Row gap={2} wrap style={{ padding: 2, borderRadius: 8, backgroundColor: c().field }}>
              {(
                [
                  ["all", "全部", counts().total],
                  ["active", "活跃", counts().active],
                  ["paused", "已暂停", counts().paused],
                  ["unused", "未使用", counts().unused],
                ] as const
              ).map(([key, label, count]) => {
                const on = () => clientFilter() === key;
                return (
                  <View
                    role="tab"
                    testID={`ai-filter-${key}`}
                    accessibilityLabel={`${label} ${count}`}
                    accessibilityState={{ selected: on() }}
                    onPress={() => clientFilter.set(key)}
                    style={{
                      flexDirection: "row",
                      alignItems: "center",
                      gap: 4,
                      paddingHorizontal: 9,
                      height: fs(25),
                      borderRadius: 6,
                      backgroundColor: on() ? c().surface : "transparent",
                      cursor: "pointer",
                    }}
                  >
                    <T size={11.5} weight={on() ? "600" : "400"} color={on() ? c().blue : c().muted}>{label}</T>
                    <T size={10.5} color={on() ? c().blue : c().faint}>{String(count)}</T>
                  </View>
                );
              })}
            </Row>
            <View style={{ width: props.compact() ? "100%" : 210 }}>
              <TextBox
                testID="ai-client-search"
                label="搜索已配对客户端"
                placeholder="搜索名称、备注或指纹…"
                value={clientSearch()}
                onChange={(v) => clientSearch.set(v)}
              />
            </View>
          </Row>
        </If>

        <If
          when={counts().total > 0}
          else={
            <View style={{ paddingVertical: 22, paddingHorizontal: 14, alignItems: "center", gap: 4, borderRadius: 9, borderWidth: 1, borderColor: c().line, backgroundColor: c().soft2 }}>
              <T size={12.5} weight="600">暂无已配对客户端</T>
              <T size={11.5} color={c().muted}>点击上方「配对客户端」一键生成含令牌的 MCP 配置。</T>
            </View>
          }
        >
          <If
            when={filtered().length > 0}
            else={
              <View style={{ paddingVertical: 20, paddingHorizontal: 14, alignItems: "center", gap: 6, borderRadius: 9, borderWidth: 1, borderColor: c().line, backgroundColor: c().soft2 }}>
                <T size={12.5} weight="600">当前筛选下没有匹配的客户端</T>
                <T size={11} color={c().muted}>可切换状态筛选或清空搜索关键词。</T>
                <Btn label="重置筛选" kind="ghost" onPress={() => { clientFilter.set("all"); clientSearch.set(""); }} />
              </View>
            }
          >
            <View style={{ borderWidth: 1, borderColor: c().line, borderRadius: radius.card, overflow: "hidden", backgroundColor: c().surface }}>
              <Each of={filtered()} key={(item) => item.id}>
                {(item) => {
                  const open = () => expandedClientId() === item().id;
                  const auditOn = () => auditClientId() === item().id;
                  return (
                    <View
                      testID={`ai-client-row-${item().id}`}
                      style={{
                        borderBottomWidth: 1,
                        borderBottomColor: c().line2,
                        backgroundColor: open() ? c().blueSoft : c().surface,
                      }}
                    >
                      <Row
                        gap={8}
                        style={{
                          paddingHorizontal: 11,
                          paddingVertical: 10,
                          alignItems: "center",
                          cursor: "pointer",
                        }}
                      >
                        <View
                          role="button"
                          accessibilityLabel={`展开或收起 ${item().name}`}
                          onPress={() => expandedClientId.set(open() ? null : item().id)}
                          style={{ flex: 1, minWidth: 0, flexDirection: "row", alignItems: "center", gap: 8, cursor: "pointer" }}
                        >
                          <Icon name={open() ? "chevd" : "chev"} size={12} tint={c().faint} />
                          <StatusDot state={item().state} />
                          <View style={{ flex: 1, minWidth: 0, gap: 2 }}>
                            <Row gap={6} wrap>
                              <T size={12.5} weight="600" color={item().paused ? c().muted : c().ink}>{item().name}</T>
                              <If
                                when={!!item().note}
                                else={
                                  <View
                                    role="button"
                                    accessibilityLabel={`为 ${item().name} 添加备注`}
                                    onPress={(e: any) => { e?.stopPropagation?.(); openEditClientSheet(item()); }}
                                    style={{ paddingHorizontal: 5, paddingVertical: 1, borderRadius: 4, borderWidth: 1, borderColor: c().line, cursor: "pointer" }}
                                    hoverStyle={{ backgroundColor: c().blueSoft, borderColor: c().blueLine }}
                                  >
                                    <T size={10.5} color={c().faint}>+ 备注</T>
                                  </View>
                                }
                              >
                                <Pill tone="blue">{item().note}</Pill>
                              </If>
                              <FingerprintChip fp={item().fingerprint} />
                              <Pill tone={stateTone(item().state)}>{clientStateLabel(item().state)}</Pill>
                              <If when={item().hasLease}>
                                <Pill tone="blue">免确认中</Pill>
                              </If>
                            </Row>
                            <T size={11} color={c().muted} lines={1}>{clientSubline(item())}</T>
                          </View>
                        </View>

                        <If
                          when={open()}
                          else={
                            <Row gap={3}>
                              <SoftActionBtn
                                label={item().paused ? "恢复" : "暂停"}
                                icon={item().paused ? "play" : "pause"}
                                tone={item().paused ? "blue" : "default"}
                                onPress={() => void togglePauseClient(item())}
                              />
                              <IconBtn icon="edit" size={14} label="编辑名称与备注" onPress={() => openEditClientSheet(item())} />
                              <IconBtn
                                icon="history"
                                size={14}
                                label={auditOn() ? "取消日志筛选" : "只看此客户端日志"}
                                tint={auditOn() ? c().blue : c().muted}
                                onPress={() => toggleAuditFilter(item())}
                              />
                              <IconBtn
                                icon="more"
                                size={14}
                                label="更多操作"
                                onPress={(e: any) => void Menu.popup(rowMenu(item()), e?.pagePosition)}
                              />
                            </Row>
                          }
                        >
                          <Btn label="收起" kind="ghost" onPress={() => expandedClientId.set(null)} />
                        </If>
                      </Row>

                      <If when={open()}>
                        <View
                          testID="ai-client-inline-drawer"
                          style={{
                            paddingLeft: props.compact() ? 12 : 34,
                            paddingRight: 12,
                            paddingVertical: 11,
                            gap: 9,
                            borderTopWidth: 1,
                            borderTopColor: c().line2,
                            backgroundColor: c().soft2,
                          }}
                        >
                          <Row gap={14} wrap style={{ alignItems: "flex-start" }}>
                            <View style={{ flex: 1, minWidth: 200, gap: 2 }}>
                              <T size={10.5} color={c().faint}>令牌短指纹</T>
                              <Row gap={6} wrap>
                                <FingerprintChip fp={item().fingerprint} prefix="tok_" />
                                <T size={10.5} color={c().muted}>明文仅配对时显示一次</T>
                              </Row>
                            </View>
                            <View style={{ flex: 1, minWidth: 200, gap: 2 }}>
                              <T size={10.5} color={c().faint}>配对与通道</T>
                              <T size={11.5}>{`${formatPairedTime(item().createdUnix)} · 本机 Unix Socket · pv-mcp`}</T>
                            </View>
                          </Row>
                          <Row gap={14} wrap style={{ alignItems: "flex-start" }}>
                            <View style={{ flex: 1, minWidth: 200, gap: 2 }}>
                              <T size={10.5} color={c().faint}>最近操作与调用</T>
                              <T size={11.5}>{`${item().lastOpLabel} · 近 24h ${item().calls24h} 次 / 共 ${item().callsTotal} 次`}</T>
                            </View>
                            <View style={{ flex: 1, minWidth: 200, gap: 2 }}>
                              <T size={10.5} color={c().faint}>生效访问范围</T>
                              <T size={11.5}>{props.scopeSummary()}</T>
                            </View>
                          </Row>

                          <If when={item().paused}>
                            <Row gap={6} style={{ paddingHorizontal: 10, paddingVertical: 6, borderRadius: 7, backgroundColor: c().orangeSoft }}>
                              <Icon name="alert" size={13} tint={c().orange} />
                              <T size={11} color={c().orange} style={{ flex: 1 }}>
                                已暂停访问：此客户端的 MCP 请求会被立即拒绝，保留原配置以便随时点「恢复」。
                              </T>
                            </Row>
                          </If>

                          <Row gap={6} wrap style={{ paddingTop: 8, borderTopWidth: 1, borderTopColor: c().line2 }}>
                            <SoftActionBtn label="编辑名称与备注" icon="edit" onPress={() => openEditClientSheet(item())} />
                            <SoftActionBtn
                              label={auditOn() ? "已筛选日志（取消）" : "只看它的日志"}
                              icon="history"
                              tone={auditOn() ? "blue" : "default"}
                              onPress={() => toggleAuditFilter(item())}
                            />
                            <SoftActionBtn
                              label={item().paused ? "恢复访问" : "暂停访问"}
                              icon={item().paused ? "play" : "pause"}
                              tone={item().paused ? "blue" : "default"}
                              onPress={() => void togglePauseClient(item())}
                            />
                            <Spacer />
                            <SoftActionBtn label="撤销客户端" icon="trash" tone="danger" onPress={() => revokeClientWithConfirm(item())} />
                          </Row>
                        </View>
                      </If>
                    </View>
                  );
                }}
              </Each>
            </View>
          </If>
        </If>
      </Card>
    </View>
  );
}
