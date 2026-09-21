export function sync(items: Item[], client: Client) {
  const pending = items.filter((item) => !item.synced);
  for (const item of pending) {
    client.upload(item.id, item.payload);
    item.synced = true;
  }
  return pending.length;
}
