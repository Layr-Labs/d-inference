import { Header } from "../components/header";
import { Footer } from "../components/footer";
import {
  DeveloperSection,
  EarnSection,
  FAQSection,
  FinalCTA,
  Hero,
  NetworkSection,
  PricingSection,
  PrivacySection,
} from "../components/sections";

export default function Home() {
  return (
    <>
      <a className="skip-link" href="#main">
        Skip to content
      </a>
      <Header />
      <main id="main">
        <Hero />
        <NetworkSection />
        <PrivacySection />
        <DeveloperSection />
        <PricingSection />
        <EarnSection />
        <FAQSection />
        <FinalCTA />
      </main>
      <Footer />
    </>
  );
}
