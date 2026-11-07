// Live one-time codes: one clock for the whole app, codes computed by the core.
import { effect, signal, Text } from "nsh";
import { totpCode } from "./store";

const nowSeconds = signal(Math.floor(Date.now() / 1000));
setInterval(() => nowSeconds.set(Math.floor(Date.now() / 1000)), 1000);

export const secondsLeft = (period = 30) => period - (nowSeconds() % period);
export const formatCode = (code: string) => (code.length === 6 ? `${code.slice(0, 3)} ${code.slice(3)}` : code.length === 8 ? `${code.slice(0, 4)} ${code.slice(4)}` : code);

/** The current code of `secret`, refreshed when its period turns over. */
export function useCode(secret: () => string, period: () => number) {
  const code = signal("");
  let last = "";
  effect(() => {
    const window = Math.floor(nowSeconds() / period());
    const key = `${secret()}|${period()}|${window}`;
    if (key === last) return;
    last = key;
    const s = secret();
    if (!s) return code.set("");
    totpCode(s, period()).then((value) => {
      if (last === key) code.set(value);
    });
  });
  return code;
}

export function TotpText(props: { secret: string; period: number; style?: any }) {
  const code = useCode(() => props.secret, () => props.period);
  return <Text style={props.style}>{code() ? formatCode(code()) : "——— ———"}</Text>;
}
