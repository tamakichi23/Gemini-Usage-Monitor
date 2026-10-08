import { UsageError } from './parser.mjs';

// Never return an exception message: it may contain private URLs or launch details.
export function classify(error, stage) {
  if (error instanceof UsageError) return error.code;
  if (error?.name === 'TimeoutError') return 'timeout';
  if (stage === 'launch') return 'browser_launch_failed';
  if (stage === 'collect') return 'browser_or_network_error';
  if (stage === 'publish') return 'snapshot_write_failed';
  return 'operation_failed';
}
