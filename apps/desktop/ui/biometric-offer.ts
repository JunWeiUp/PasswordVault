// When to offer Touch ID right after a new vault is created.
export function shouldOfferBiometrics(o: { mac: boolean; available: boolean; enabled: boolean; restoring: boolean }): boolean {
  // A restore continues straight into the backup import; offer later from Settings instead.
  return o.mac && o.available && !o.enabled && !o.restoring;
}
