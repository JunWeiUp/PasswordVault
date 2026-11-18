// Member key display: the signed group entry pins each member's Ed25519 signing key.
/** Formats a hex public key as upper-case groups of four, or "" if it is not hex. */
export function keyFingerprint(hex: unknown): string {
  if (typeof hex !== "string" || !/^[0-9a-fA-F]{16,128}$/.test(hex) || hex.length % 2) return "";
  return hex.toUpperCase().match(/.{1,4}/g)!.join(" ");
}
