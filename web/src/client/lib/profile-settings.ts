export function profileSettingsChanges(
  me: { publicProfileDisplayName: string | null; publicProfileUsername: string | null },
  fields: FormData,
  enable: boolean,
) {
  const displayName = String(fields.get("displayName") ?? "");
  const username =
    String(fields.get("username") ?? "")
      .trim()
      .toLowerCase() || null;
  // Compare the raw input before normalizing so an untouched name isn't sent back as an edit.
  return {
    publicProfileDisplayName:
      displayName !== (me.publicProfileDisplayName ?? "") ? displayName.trim() || null : undefined,
    publicProfileUsername: username !== me.publicProfileUsername ? username : undefined,
    publicProfileEnabled: enable ? true : undefined,
  };
}
