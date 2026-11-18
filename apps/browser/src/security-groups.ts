// Groups security-audit findings by issue for the Security Checks page.
export type SecurityGroupKey = "weak" | "reused" | "breach" | "expired" | "twoFactor" | "passkey" | "other";
export const SECURITY_GROUP_ORDER: SecurityGroupKey[] = ["weak", "reused", "breach", "expired", "twoFactor", "passkey", "other"];
export type SecurityGroup<F> = { key: SecurityGroupKey; count: number; findings: F[] };
type Finding = { kind?: string; id?: string; weak?: boolean; reused?: boolean; expired?: boolean; ignored?: boolean };

/**
 * One finding may belong to several groups (a weak, reused password). Ignored findings
 * stay listed but are not counted. `breached` holds item IDs that this session's
 * opt-in breach check reported; they form the breach group as synthetic entries.
 * Empty groups are omitted.
 */
export function groupSecurityFindings<F extends Finding>(findings: readonly F[], breached: readonly { id: string; title?: string }[] = []): SecurityGroup<F | { kind: "breach"; id: string; title?: string; key: string }>[] {
  const buckets = new Map<SecurityGroupKey, any[]>(SECURITY_GROUP_ORDER.map((key) => [key, []]));
  for (const finding of findings) {
    if (finding.kind === "passwordHealth") {
      if (finding.weak === true) buckets.get("weak")!.push(finding);
      if (finding.reused === true) buckets.get("reused")!.push(finding);
      if (finding.expired === true) buckets.get("expired")!.push(finding);
      if (finding.weak !== true && finding.reused !== true && finding.expired !== true) buckets.get("other")!.push(finding);
    } else if (finding.kind === "twoFactorAvailable") buckets.get("twoFactor")!.push(finding);
    else if (finding.kind === "passkeyAvailable") buckets.get("passkey")!.push(finding);
    else buckets.get("other")!.push(finding);
  }
  for (const item of breached) buckets.get("breach")!.push({ kind: "breach", id: item.id, title: item.title, key: `breach:${item.id}` });
  return SECURITY_GROUP_ORDER.map((key) => {
    const list = buckets.get(key)!;
    return { key, findings: list, count: list.filter((f) => f.ignored !== true).length };
  }).filter((group) => group.findings.length > 0);
}
