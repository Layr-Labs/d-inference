import type { NextConfig } from "next";
import createNextIntlPlugin from "next-intl/plugin";

const nextConfig: NextConfig = {
  typescript: {
    // @noble/curves >=1.9 ships raw .ts files with .ts import extensions,
    // which fails Next.js type-checking even with skipLibCheck: true.
    // This is a known upstream issue in viem's dependency tree.
    ignoreBuildErrors: true,
  },
};

const withNextIntl = createNextIntlPlugin();

export default withNextIntl(nextConfig);
