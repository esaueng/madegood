import { createFileRoute } from "@tanstack/react-router";
import { PrivacyPolicy } from "@/components/privacy-policy";

export const Route = createFileRoute("/privacy")({
  component: PrivacyPolicy,
});
