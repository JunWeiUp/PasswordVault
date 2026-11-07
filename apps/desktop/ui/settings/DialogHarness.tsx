import { mount, View } from "nsh";
import { SettingsHost, openSettings } from "../Settings";
import { Btn, SheetHost, openSheet, T } from "../kit";
export default function App() {
  return <View><Btn label="打开设置测试" onPress={() => openSettings("about")} />
    <Btn label="打开弹窗测试" onPress={() => openSheet({render: () => <T>测试弹窗内容</T>})} />
    <SettingsHost /><SheetHost /></View>;
}
mount(App);
