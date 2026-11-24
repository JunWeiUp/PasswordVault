// Pure TS vault item metadata, destination mapping, and error localization.
// Zero NSH runtime dependency so it can be unit-tested in milliseconds and
// changed via --ui-only deploy without recompiling Rust.

export type ItemType =
  | "password"
  | "totp"
  | "crypto"
  | "secureNote"
  | "creditCard"
  | "identity"
  | "device";

export type Item = { id: string; type: ItemType; title: string; uiMeta?: Record<string, any>; [key: string]: any };

export type Dest =
  | "all"
  | "accounts"
  | "codes"
  | "wallets"
  | "notes"
  | "devices"
  | "favorites"
  | "trash"
  | "generator"
  | "health"
  | "ai";

export type Phase = "loading" | "onboard" | "locked" | "unlocked";

export const DEST_TYPES: Partial<Record<Dest, ItemType[]>> = {
  accounts: ["password"],
  codes: ["totp"],
  wallets: ["creditCard", "identity", "crypto"],
  notes: ["secureNote"],
  devices: ["device"],
};

export const DEST_NAME: Record<Dest, string> = {
  all: "全部项目",
  accounts: "账号",
  codes: "验证码",
  wallets: "钱包",
  notes: "笔记",
  devices: "设备与服务",
  favorites: "收藏",
  trash: "回收站",
  generator: "密码生成器",
  health: "密码健康",
  ai: "AI 访问",
};

export const TYPE_NAME: Record<ItemType, string> = {
  password: "账号",
  totp: "验证码",
  crypto: "加密钱包",
  secureNote: "笔记",
  creditCard: "银行卡",
  identity: "身份信息",
  device: "设备",
};

export const ERROR_TEXT: Record<string, string> = {
  Locked: "密码库已锁定。",
  Authentication: "主密码不正确，或加密数据已损坏。",
  InvalidData: "数据无效或不受支持。",
  AlreadyExists: "该位置已存在密码库。",
  InUse: "密码库正被另一个进程使用。请先退出其他 PasswordVault。",
  Storage: "写入失败，已保留原有数据。",
  StaleEdit: "此条目已在其他设备上修改，请检查后再保存。",
  Unsupported: "此操作不受支持。",
  DevicesUpgradeRequired: "请先启用设备与服务。",
  DevicesSyncBlocked: "对端尚未验证格式兼容性，请升级并解锁对端后重试。",
  UpdateRequired: "请更新客户端以打开此密码库。",
};

export const errorText = (e: unknown): string =>
  ERROR_TEXT[String(e).replace(/^Error:\s*/, "")] ?? String(e);

export const destOf = (type: ItemType): Dest =>
  (Object.keys(DEST_TYPES) as Dest[]).find((d) => DEST_TYPES[d]!.includes(type)) ?? "all";

export function inDest(item: Item, d: Dest): boolean {
  if (d === "trash") return !!item.isDeleted;
  if (item.isDeleted) return false;
  if (d === "all") return true;
  if (d === "favorites") return !!item.isFavorite;
  return DEST_TYPES[d]?.includes(item.type) ?? false;
}
