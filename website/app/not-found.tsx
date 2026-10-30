import Link from "next/link";

export default function NotFound() {
  return (
    <div className="container section" style={{ textAlign: "center" }}>
      <p className="eyebrow">404</p>
      <h1 className="section-title">This page never passed review.</h1>
      <p className="section-lede" style={{ marginInline: "auto" }}>
        The page you asked for doesn&rsquo;t exist — or the checker refused it.
      </p>
      <Link className="button button-ghost" href="/">
        Back to secondmate
      </Link>
    </div>
  );
}
