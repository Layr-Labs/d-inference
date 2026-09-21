import type { Metadata } from "next";
import { AboutExperience } from "../../components/AboutExperience";

export const metadata: Metadata = {
  title: "About",
  description: "Private, decentralized inference on verified Apple Silicon hardware.",
};

export default function AboutPage() {
  return <AboutExperience />;
}
