import { useQuery, useQueryClient } from "@tanstack/react-query";
import { deleteAccount, fetchMe, signOut } from "./api";

export const meQueryKey = ["me"] as const;

/** The signed-in user (null when signed out). */
export function useMe() {
  return useQuery({ queryKey: meQueryKey, queryFn: fetchMe, staleTime: 60_000 });
}

export function useSignOut() {
  const queryClient = useQueryClient();
  return async () => {
    await signOut();
    queryClient.clear();
    queryClient.setQueryData(meQueryKey, null);
  };
}

/** Deletes the account, then forgets everything cached for it, as a sign-out does. */
export function useDeleteAccount() {
  const queryClient = useQueryClient();
  return async (userId: string) => {
    await deleteAccount(userId);
    queryClient.clear();
    queryClient.setQueryData(meQueryKey, null);
  };
}
