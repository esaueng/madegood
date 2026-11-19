import { Globe, Link2, Lock } from "lucide-react";
import type { Visibility } from "@/lib/api";

export const VISIBILITY = {
  private: { icon: Lock, label: "Private", hint: "Only you can see it." },
  unlisted: { icon: Link2, label: "Unlisted", hint: "Anyone with the link can see it." },
  public: { icon: Globe, label: "Public", hint: "Anyone can see it." },
} as const satisfies Record<Visibility, unknown>;
