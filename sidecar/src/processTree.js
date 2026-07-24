import { spawnSync } from 'node:child_process';

/**
 * Terminate a backend process and all of its descendants.
 *
 * On Windows the adapters launch CLI shims through shell:true. child.kill()
 * only terminates the shell wrapper and can leave claude/codex plus MCP
 * grandchildren running. taskkill /T targets the exact spawned PID tree.
 */
export function terminateProcessTree(child, {
  platform = process.platform,
  run = spawnSync,
} = {}) {
  if (!child) return false;

  if (platform === 'win32' && Number.isInteger(child.pid) && child.pid > 0) {
    try {
      const result = run('taskkill.exe', ['/PID', String(child.pid), '/T', '/F'], {
        windowsHide: true,
        stdio: 'ignore',
      });
      if (!result?.error && result?.status === 0) return true;
    } catch {
      // Fall through to the direct child termination below.
    }
  }

  try {
    return child.kill('SIGTERM') !== false;
  } catch {
    return false;
  }
}
