import { CONSOLE_URL, PAPER_URL, REPO_URL } from "../lib/links";
import { Arrow, Mark } from "./ui";

export function Footer() {
  return (
    <footer className="container footer">
      <div className="footer-main">
        <div>
          <a href="#" className="brand">
            <Mark />
            <span>darkbloom</span>
          </a>
          <p>Intelligence, in good hands.</p>
          <span className="footer-byline">BUILT BY EIGEN LABS</span>
        </div>
        <nav aria-label="Product links">
          <span>EXPLORE</span>
          <a href={CONSOLE_URL}>
            Console <Arrow diagonal />
          </a>
          <a href={`${CONSOLE_URL}/earn`}>
            Run a node <Arrow diagonal />
          </a>
          <a href={PAPER_URL}>
            Research paper <Arrow diagonal />
          </a>
        </nav>
        <nav aria-label="Community links">
          <span>CONNECT</span>
          <a href={REPO_URL}>
            GitHub <Arrow diagonal />
          </a>
          <a href="https://x.com/eigen_labs">
            X / Twitter <Arrow diagonal />
          </a>
          <a href="https://www.linkedin.com/company/eigenlabsorg">
            LinkedIn <Arrow diagonal />
          </a>
        </nav>
      </div>
      <div className="footer-bottom">
        <span>
          © {new Date().getFullYear()} Eigen Labs. All rights reserved.
        </span>
        <div>
          <a href="/terms.html">Terms of service</a>
          <a href="/privacy.html">Privacy policy</a>
          <a href="#privacy">Security</a>
        </div>
      </div>
    </footer>
  );
}
