import type { MyProvider } from "../types";
import { ProofDetails } from "@/components/verification/ProofDetails";
import { currentVerification } from "@/lib/verification";

export function AppAttestPanel({ provider }: { provider: MyProvider }) {
  return <ProofDetails verification={currentVerification(provider.verification)} />;
}
