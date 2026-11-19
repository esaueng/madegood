/**
 * The Apple account's MadeGood account is being deleted (lib/account-deletion.ts): it
 * cannot sign in or get new tokens until the deletion has finished.
 */
export class AccountDeleting extends Error {
  constructor(
    readonly userId?: string,
    readonly deletedAt?: number,
  ) {
    super("account_deleting");
  }
}
