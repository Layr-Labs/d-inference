import type { Metadata } from "next";
import { HomeExperience } from "../components/HomeExperience";

export const metadata: Metadata = { alternates: { canonical: "/" } };

export default function Home() {
  return <HomeExperience />;
}
