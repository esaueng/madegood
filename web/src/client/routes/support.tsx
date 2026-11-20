import { createFileRoute } from "@tanstack/react-router";
import { useEffect } from "react";
import { questionId, SupportPage } from "@/components/support-page";

export const Route = createFileRoute("/support")({
  component: Support,
});

function Support() {
  // Open the question a link points at, such as /support#delete-account.
  useEffect(() => {
    const id = questionId(window.location.hash);
    const target = id ? document.getElementById(id) : null;
    if (target instanceof HTMLDetailsElement) {
      target.open = true;
      target.scrollIntoView();
    }
  }, []);
  return <SupportPage />;
}
