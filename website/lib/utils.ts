/* Minimal class-name joiner -- the signature the shadcn-registry icon
   components import (`cn` from "@/lib/utils"), without the clsx
   dependency: plain truthy-string join. */

export function cn(...inputs: (string | undefined | null | false)[]): string {
  return inputs.filter(Boolean).join(" ");
}
