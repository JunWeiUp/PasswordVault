// PasswordVault mobile UI on Native Shell, embedded in the iOS and Android apps.
// Pilot: the verification-codes page. The host app owns the vault and all secrets.
import { mount } from "nsh";
import { Codes } from "./ui/Codes";

mount(Codes);
