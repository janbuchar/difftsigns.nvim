export function sync(items: Item[], client: Client) {
  const pending = items.filter((item) => !item.synced);
  if (client.isConnected()) {
    for (const item of pending) {
      client.upload(item.id, item.payload, { retry: 3 });
      item.synced = true;
    }
  }
  return pending.length;
}
