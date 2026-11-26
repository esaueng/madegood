import { useQuery } from "@tanstack/react-query";
import { fetchSiteConfig } from "@/lib/api";

export const siteConfigQuery = { queryKey: ["site-config"], queryFn: fetchSiteConfig } as const;

export const useSiteConfig = () => useQuery(siteConfigQuery);

/**
 * Whether sharing is available on this server (GET /api/config `sharing`). False until the
 * configuration loads, so no sharing control flashes in while sharing is unavailable.
 */
export const useSharingAvailable = () => useSiteConfig().data?.sharing === true;
