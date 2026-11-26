/**
 * The deployment-wide sharing switch: `SHARING=on` turns sharing on; unset (the default)
 * or any other value keeps it off.
 *
 * With it off, nothing can be shared: new accounts start with their own switch
 * (`users.sharing_enabled`) off, `PATCH /me` refuses to turn it on or share anything
 * (409 `sharing_disabled`), and every other way to share already needs that account switch
 * (unlisted or public sessions, the public profile, live voyage links). Migration
 * 0018_sharing_unavailable turned every account's switch off and made everything private,
 * so nothing shared before stays readable.
 *
 * Turning it on shares nothing by itself; each account still turns its own switch on.
 * Turning it off again after that does not unshare what was shared meanwhile: do that with
 * a migration like 0018.
 */
export const sharingAvailable = (env: Pick<Env, "SHARING">) => env.SHARING === "on";
