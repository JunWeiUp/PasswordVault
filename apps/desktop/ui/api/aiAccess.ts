// Typed labels, error localization, and pure formatting helpers for Tools → AI 访问.
import { errorText } from "../store";

export const AI_ERRORS: Record<string, string> = {
  ApprovalDenied: "已拒绝本次读取",
  ApprovalTimeout: "60 秒未确认，已自动拒绝",
  Busy: "待审批请求过多，请稍后再试",
  DeniedField: "该字段不允许 AI 读取",
  Disabled: "本机 AI 接口未启用",
  EntryChanged: "条目在审批期间已修改，请重新请求",
  Locked: "密码库已锁定",
  ReadOnlyUnsupportedOperation: "执行请求已拒绝 · PasswordVault 不执行命令",
  Unsupported: "执行请求已拒绝 · PasswordVault 不执行命令",
  RevokedOrUnknownClient: "客户端已撤销或不存在",
  ClientPaused: "该客户端已暂停访问，可在「AI 访问」中一键恢复",
  UnknownClient: "客户端已撤销或不存在",
  UnscopedOrMissing: "条目不存在、已对 AI 隐藏，或所属类别未开启",
  NoteWriteDisabled: "尚未开启笔记免弹窗自动保存",
  NoteWriteDenied: "目标目录不在 AI 可写白名单中",
  CategoryNotWritable: "目标目录不在 AI 可写白名单中",
  MissingSummary: "AI 写入笔记必须提供变更摘要（summary）",
  SummaryRequired: "AI 写入笔记必须提供变更摘要（summary）",
  VersionConflict: "笔记已被更新，请重新读取最新版本后再写入",
  SectionNotFound: "未找到指定的 Markdown 标题章节",
  EmptyContent: "写入内容不能为空",
  RateLimited: "写入过于频繁，请稍后再试",
  AssetTooLarge: "单个附件文件不能超过 100 MB",
  AssetAccessDisabled: "已关闭笔记资产归档与文档文本读取",
  AssetTextDenied: "该附件尚未开启「AI 可读文本」，请在笔记附件栏手动开启",
  UnsupportedFormat: "该文件格式暂不支持提取纯文本",
  MissingFile: "未找到指定的附件",
};

export const aiError = (e: unknown): string =>
  AI_ERRORS[String(e).replace(/^Error:\s*/, "")] ?? errorText(e);

export const AI_RESULTS: Record<string, string> = {
  Allowed: "已允许",
  AllowedByLease: "免确认放行",
  ApprovalDenied: "已拒绝",
  ApprovalTimeout: "超时拒绝",
  ClientPaused: "已暂停拒绝",
  Locked: "锁定拒绝",
  DeferredAuditFlushed: "解锁后补记",
};

export const AI_OPS: Record<string, string> = {
  find: "查找",
  read: "读取",
  create: "新建",
  update: "修改",
  delete: "移到回收站",
  unsupported: "执行请求",
};

export function relativeAuditTime(seconds: number): string {
  const diff = Math.max(0, Date.now() / 1000 - seconds);
  if (diff < 60) return "刚刚";
  if (diff < 3600) return `${Math.floor(diff / 60)} 分钟前`;
  if (diff < 86400) return `${Math.floor(diff / 3600)} 小时前`;
  return new Date(seconds * 1000).toLocaleDateString();
}
