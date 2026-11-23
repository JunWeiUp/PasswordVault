// Synthetic passkey prompt fixture: records the answer instead of calling the bridge.
import { mount, signal, View } from "nsh";
import { SheetHost, T } from "../kit";
import { openPasskeyPrompt } from "./passkey";

const answer = signal("");
openPasskeyPrompt({ challenge: "c", passkey: { operation: "get", origin: "https://login.example.com", rpId: "example.com", matches: [
      { library: "", itemId: "i1", id: "k1", userName: "alice" },
      { library: "shared", itemId: "i2", id: "k2", userName: "bob" },
  ] } },
  (s) => answer.set(JSON.stringify(s)), () => answer.set("cancelled"));
mount(() => <View><T>{`answer:${answer()}`}</T><SheetHost /></View>);
