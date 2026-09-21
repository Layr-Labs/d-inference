"use client";

import Link from "next/link";
import Image from "next/image";
import { usePathname } from "next/navigation";

export function Logo({ onDark = true }: { onDark?: boolean }) {
  const pathname = usePathname();
  return (
    <Link
      className="brand"
      href="/"
      aria-label="Darkbloom — back to the top of the page"
      data-dark={onDark ? "true" : "false"}
      onClick={(event) => {
        // On the landing page the logo acts as a home button: glide back to
        // the top instead of re-navigating, so the pinned scroll stages rewind.
        if (pathname === "/") {
          event.preventDefault();
          const handled = !window.dispatchEvent(new Event("darkbloom:scroll-top", { cancelable: true }));
          if (!handled) window.scrollTo({ top: 0, behavior: "smooth" });
        }
      }}
    >
      <Image src="/logo.svg" alt="" width={89} height={11} priority />
    </Link>
  );
}
