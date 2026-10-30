import type { Metadata, Viewport } from "next";
import "./globals.css";
import { SiteHeader } from "@/components/SiteHeader";
import { SiteFooter } from "@/components/SiteFooter";
import { StatsTicker } from "@/components/StatsTicker";
import { getPluginMeta, getGithubStars, getCloneCount } from "@/lib/repo";
import { getReadme } from "@/lib/parse";

const plugin = getPluginMeta();
const readme = getReadme();
const description = readme.taglineLines.join(" ");
const stars = await getGithubStars(plugin.homepage);
const clones = getCloneCount();

export const metadata: Metadata = {
  metadataBase: new URL(plugin.homepage),
  title: {
    default: "secondmate",
    template: "%s — secondmate",
  },
  description,
  openGraph: {
    title: "secondmate",
    description,
    url: plugin.homepage,
    siteName: "secondmate",
    type: "website",
  },
};

export const viewport: Viewport = {
  themeColor: "#0f1013",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <SiteHeader githubUrl={plugin.homepage} />
        <StatsTicker
          version={plugin.version}
          mitLicensed={readme.mitLicensed}
          stars={stars}
          clones={clones}
        />
        <main>{children}</main>
        <SiteFooter
          githubUrl={plugin.homepage}
          version={plugin.version}
          mitLicensed={readme.mitLicensed}
        />
      </body>
    </html>
  );
}
