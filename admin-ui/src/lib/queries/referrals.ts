import "server-only";
import { query } from "@/lib/db";

export interface ReferrerRow {
  account_id: string;
  email: string | null;
  code: string;
  referred_count: string;
  created_at: string;
}

// Referrers joined to their owner's email and a count of how many accounts
// each code has referred. Ordered by recency.
export async function listReferrers(limit = 200, offset = 0): Promise<ReferrerRow[]> {
  return query<ReferrerRow>(
    `SELECT r.account_id,
            u.email,
            r.code,
            COALESCE(c.n, 0) AS referred_count,
            r.created_at
       FROM referrers r
       LEFT JOIN users u ON u.account_id = r.account_id
       LEFT JOIN (
         SELECT referrer_code, count(*) AS n
           FROM referrals
          GROUP BY referrer_code
       ) c ON c.referrer_code = r.code
      ORDER BY r.created_at DESC
      LIMIT $1 OFFSET $2`,
    [limit, offset],
  );
}

export interface InviteCodeRow {
  code: string;
  amount_micro_usd: string;
  max_uses: number;
  used_count: number;
  active: boolean;
  expires_at: string | null;
  created_at: string;
}

// Invite codes (credit grants). amount_micro_usd is BIGINT — kept as a string.
export async function listInviteCodes(limit = 200, offset = 0): Promise<InviteCodeRow[]> {
  return query<InviteCodeRow>(
    `SELECT code,
            amount_micro_usd,
            max_uses,
            used_count,
            active,
            expires_at,
            created_at
       FROM invite_codes
      ORDER BY created_at DESC
      LIMIT $1 OFFSET $2`,
    [limit, offset],
  );
}
