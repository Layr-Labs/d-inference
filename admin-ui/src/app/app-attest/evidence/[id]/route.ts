import { query } from "@/lib/db";
import { checkBasicAuth } from "@/lib/auth";

export const runtime="nodejs";
export const dynamic="force-dynamic";
export async function GET(request: Request,{params}: {params: Promise<{id:string}>}) {
  // Defense in depth for the raw archive, in addition to the global proxy.
  if (!await checkBasicAuth(request.headers.get("authorization"))) return new Response("Unauthorized",{status:401});
  const {id}=await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) return new Response("Invalid evidence ID",{status:400});
  const [record]=await query(`SELECT e.*,b.proof_field,encode(b.proof,'base64') AS proof_base64,
    s.machine_id,s.account_id FROM app_attest_evidence e JOIN app_attest_evidence_blobs b ON b.evidence_id=e.id
    LEFT JOIN darkbloom_machine_sessions s ON s.session_id=e.session_id WHERE e.id=$1`,[id]);
  if (!record) return new Response("Not found",{status:404});
  const receipts=await query(`SELECT r.*,encode(b.body,'base64') AS receipt_base64,encode(b.response_body,'base64') AS response_base64
    FROM app_attest_receipts r JOIN app_attest_receipt_blobs b ON b.receipt_id=r.id WHERE evidence_id=$1 ORDER BY received_at`,[id]);
  return Response.json({record,receipts},{headers:{"Cache-Control":"private, no-store","Content-Disposition":`attachment; filename="app-attest-${id}.json"`}});
}
