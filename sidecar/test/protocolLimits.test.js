import test from 'node:test';
import assert from 'node:assert/strict';
import { createLineBuffer } from '../src/protocol.js';

test('line buffer drops an oversized unterminated frame and recovers', () => {
  const lines = [];
  let overflows = 0;
  const feed = createLineBuffer((line) => lines.push(line), {
    maxLength: 8,
    onOverflow: () => { overflows++; },
  });
  feed('123456789');
  feed('ok\n');
  assert.equal(overflows, 1);
  assert.deepEqual(lines, ['ok']);
});
