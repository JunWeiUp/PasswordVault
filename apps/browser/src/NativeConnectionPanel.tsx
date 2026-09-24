import { connectionPresentation, type NativeState } from "./native-connection";

export function NativeConnectionPanel({
  state,
  busy,
  onOpen,
  onPair,
  onRefresh,
}: {
  state: NativeState;
  busy: boolean;
  onOpen: () => void;
  onPair: () => void;
  onRefresh: () => void;
}) {
  const view = connectionPresentation(state);
  return (
    <section class="connection-panel" aria-busy={busy}>
      <h2>{view.title}</h2>
      <p>{view.message}</p>
      {view.canPair && (
        <button class="primary wide" disabled={busy} onClick={onPair}>
          {busy ? "请在 Mac 上确认…" : "发起连接"}
        </button>
      )}
      {view.canOpen && (
        <button
          class={view.canPair ? "wide" : "primary wide"}
          disabled={busy}
          onClick={onOpen}
        >
          打开 Mac 应用
        </button>
      )}
      <button class="text-button" disabled={busy} onClick={onRefresh}>
        重新检测连接
      </button>
      <details>
        <summary>首次连接步骤</summary>
        <ol>
          <li>打开 Mac 应用并解锁资料库。</li>
          <li>进入「设置 → 浏览器」，点击「登记 Chrome / Edge 连接」。</li>
          <li>在插件中发起连接，再在 Mac 弹窗允许。</li>
        </ol>
        <p>
          移动或更新 Mac 应用后，如果连接失败，请重新登记。独立资料库与 Mac
          资料库分别保存，不会自动合并。
        </p>
      </details>
    </section>
  );
}
