// Synthetic fixture for the first-run Touch ID offer; no vault is bound, so enabling fails safely.
import { mount, View } from "nsh";
import { offerBiometricsAfterCreate } from "../ui/Settings";
import { Btn, SheetHost } from "../ui/kit";
mount(() => <View style={{ flex: 1 }}>
  <Btn label="显示 Touch ID 提示" onPress={() => offerBiometricsAfterCreate("synthetic-only")} />
  <SheetHost />
</View>);
