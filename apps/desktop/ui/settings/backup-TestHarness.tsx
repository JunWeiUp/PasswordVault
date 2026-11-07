// Synthetic UI fixture. Native file panels are never invoked headlessly.
import { mount, View } from "nsh";
import { BackupPage } from "./BackupPage";
import { SheetHost } from "../kit";
mount(()=><View><BackupPage /><SheetHost /></View>);
