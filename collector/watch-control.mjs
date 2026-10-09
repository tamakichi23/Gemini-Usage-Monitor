import { unlink } from 'node:fs/promises';

export async function consumeRefreshRequest(refreshFile) {
  if (!refreshFile) return false;
  try {
    await unlink(refreshFile);
    return true;
  } catch (error) {
    if (error.code === 'ENOENT') return false;
    throw error;
  }
}
