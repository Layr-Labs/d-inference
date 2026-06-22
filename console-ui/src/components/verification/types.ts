// Provider attestation detail surfaced in the technical verification view.
export interface ProviderDetail {
  systemVolumeHash?: string;
  sePublicKey?: string;
  mdaSerial?: string;
  mdaOsVersion?: string;
  mdaSepVersion?: string;
  mdaCertCount?: number;
}
