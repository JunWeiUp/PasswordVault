import { mount, signal, View } from "nsh";
import { DocumentLibrary } from "./DocumentLibrary";
import { Scroll } from "nsh";
import { T, SheetHost } from "../kit";
const runRequest = signal("");
const rows = signal([{ id: "python", title: "示例设备-用于检查完整长标题显示的自动备份与健康检查脚本.py", text: "#!/usr/bin/env python3\n    print('SYNTHETIC_ONLY')\n", secret: true }, { id: "config", title: "配置.json", text: "{}", secret: true }]);
mount(() => <Scroll style={{ flex: 1 }}><View style={{ padding: 24 }}><DocumentLibrary commands={rows()} editable busy={false} onRun={row => runRequest.set(row.title)} onImport={() => {}} onChange={value => rows.set(value)} /><T>{runRequest() ? "已请求终端运行" : ""}</T><SheetHost /></View></Scroll>);
