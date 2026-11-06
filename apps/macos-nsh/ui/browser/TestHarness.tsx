// Synthetic settings fixture: never registers a host or touches Keychain.
import { mount, View } from "nsh";
import { BrowserPage } from "./index";
import { SheetHost } from "../kit";
mount(() => <View><BrowserPage /><SheetHost /></View>);
