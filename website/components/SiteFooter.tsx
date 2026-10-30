import Link from "next/link";

export function SiteFooter({
  githubUrl,
  version,
  mitLicensed,
}: {
  githubUrl: string;
  version: string;
  mitLicensed: boolean;
}) {
  return (
    <footer className="site-footer">
      <div className="container">
        <span>
          secondmate v{version}
          {mitLicensed ? " · MIT License" : ""}
        </span>
        <nav className="footer-links" aria-label="Footer">
          <a href={githubUrl} target="_blank" rel="noopener noreferrer">
            GitHub
          </a>
          <Link href="/architecture/">Architecture</Link>
          <a href={`${githubUrl}#readme`} target="_blank" rel="noopener noreferrer">
            README
          </a>
        </nav>
        <p className="footer-note">
          Every word of documentation on this site is read from this repo&rsquo;s own README.md,
          docs/ARCHITECTURE.md and bin/ scripts at build time — never a hand-maintained copy.
        </p>
      </div>
    </footer>
  );
}
