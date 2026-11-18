// Verification codes: live code and countdown ring per row; tap copies, the chevron opens details.
import { effect, Scroll, signal, Text, View } from "nsh";
import { c, MONO } from "./theme";
import { codes, copy, openItem, type CodeRow } from "./host";

const rows = signal<CodeRow[]>([]);
const error = signal("");

/** "123456" → "123 456"; other lengths unchanged. */
export function grouped(code: string): string {
  if (!code) return "——— ———";
  if (code.length < 6 || code.length % 2) return code;
  return `${code.slice(0, code.length / 2)} ${code.slice(code.length / 2)}`;
}

async function refresh() {
  try {
    rows.set(await codes());
    error.set("");
  } catch {
    error.set("无法读取验证码，请稍后重试。");
  }
}

function Ring(props: { remaining: number; period: number; urgent: boolean }) {
  const size = 30;
  return (
    <View style={{ width: size, height: size, borderRadius: size / 2, borderWidth: 3, borderColor: props.urgent ? c().orange : c().blueLine, alignItems: "center", justifyContent: "center" }}>
      <Text style={{ fontSize: 11, color: props.urgent ? c().orange : c().muted }}>{String(Math.ceil(props.remaining))}</Text>
    </View>
  );
}

function Row(props: { row: CodeRow }) {
  const urgent = () => props.row.remaining <= 5;
  return (
    <View style={{ flexDirection: "row", alignItems: "center", gap: 12, paddingVertical: 14, paddingHorizontal: 16, borderBottomWidth: 1, borderBottomColor: c().line2 }}>
      <View testID={`code-${props.row.id}`} role="button" accessibilityLabel={props.row.title || "未命名"} accessibilityValue={{ text: props.row.code }}
        accessibilityHint="点按复制验证码" style={{ flex: 1, flexDirection: "row", alignItems: "center", gap: 12 }}
        onPress={() => void copy(props.row.code, "验证码")}>
        <View style={{ flex: 1, gap: 4 }}>
          <Text style={{ fontSize: 15, fontWeight: "500", color: c().ink, numberOfLines: 1 }}>{props.row.title || "未命名"}</Text>
          <Text style={{ fontSize: 28, fontFamily: MONO, color: urgent() ? c().orange : c().ink }}>{grouped(props.row.code)}</Text>
          {props.row.username ? <Text style={{ fontSize: 12, color: c().muted, numberOfLines: 1 }}>{props.row.username}</Text> : null}
        </View>
        <Ring remaining={props.row.remaining} period={props.row.period} urgent={urgent()} />
      </View>
      <View role="button" accessibilityLabel="查看详情" onPress={() => void openItem(props.row.id)} style={{ paddingHorizontal: 6, paddingVertical: 10 }}>
        <Text style={{ fontSize: 18, color: c().faint }}>›</Text>
      </View>
    </View>
  );
}

export function Codes() {
  effect(() => {
    void refresh();
    const timer = setInterval(() => void refresh(), 1000);
    return () => clearInterval(timer);
  });
  return (
    <View style={{ flex: 1, backgroundColor: c().soft }}>
      <Scroll style={{ flex: 1 }}>
        <View style={{ paddingHorizontal: 20, paddingTop: 12, paddingBottom: 8 }}>
          <Text style={{ fontSize: 30, fontWeight: "700", color: c().ink }}>验证码</Text>
        </View>
        {error() ? <Text style={{ marginHorizontal: 20, color: c().red }}>{error()}</Text> : null}
        {rows().length === 0 && !error()
          ? <Text style={{ margin: 20, color: c().muted }}>还没有验证码。可在右上角添加。</Text>
          : <View style={{ marginHorizontal: 16, borderRadius: 14, backgroundColor: c().surface, overflow: "hidden" }}>
              {rows().map((row) => <Row row={row} />)}
            </View>}
      </Scroll>
    </View>
  );
}
