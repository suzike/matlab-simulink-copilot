import test from 'node:test';
import assert from 'node:assert/strict';
import { terminateProcessTree } from '../src/processTree.js';

test('Windows 终止整个后端进程树而不是只杀 shell 包装器', () => {
  let directKills = 0;
  let invocation;
  const child = { pid: 4321, kill() { directKills += 1; return true; } };
  const ok = terminateProcessTree(child, {
    platform: 'win32',
    run(command, args, options) {
      invocation = { command, args, options };
      return { status: 0 };
    },
  });

  assert.equal(ok, true);
  assert.equal(directKills, 0);
  assert.equal(invocation.command, 'taskkill.exe');
  assert.deepEqual(invocation.args, ['/PID', '4321', '/T', '/F']);
  assert.equal(invocation.options.windowsHide, true);
});

test('Windows 进程树命令失败时回退到直接终止子进程', () => {
  let directKills = 0;
  const child = { pid: 4321, kill(signal) { directKills += 1; assert.equal(signal, 'SIGTERM'); return true; } };
  const ok = terminateProcessTree(child, {
    platform: 'win32',
    run: () => ({ status: 128 }),
  });

  assert.equal(ok, true);
  assert.equal(directKills, 1);
});

test('非 Windows 平台直接终止子进程', () => {
  let signal;
  const ok = terminateProcessTree({ kill(value) { signal = value; return true; } }, { platform: 'linux' });
  assert.equal(ok, true);
  assert.equal(signal, 'SIGTERM');
});
