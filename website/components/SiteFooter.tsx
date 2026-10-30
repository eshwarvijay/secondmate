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
      </div>
    </footer>
  );
}
