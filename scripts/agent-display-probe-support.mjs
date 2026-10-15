// Pure parsing/evidence helpers; importing this module never starts a probe.
export function applicationSerialNumbers(output) {
  if (!output.trim()) return [];
  // `front` returns ASN:0x0-0x123:, but `find` includes the display name:
  // ASN:0x0-0x123-"OpenCU_Agent_Display_Fixture":
  const matches = [...output.matchAll(/\b(ASN:0x[\da-f]+[-:]0x[\da-f]+)(?=:|-(?:"[^"\r\n]*")?:)/gi)];
  if (!matches.length) throw new Error(`Unrecognized lsappinfo find output: ${output.trim()}`);
  return [...new Set(matches.map(match => match[1] + ':'))];
}

export function applicationPID(output) {
  const pid = Number(output.match(/\bpid"?\s*=\s*(\d+)/i)?.[1]);
  if (!Number.isInteger(pid) || pid <= 1) throw new Error(`Could not resolve fixture PID from LaunchServices: ${output.trim()}`);
  return pid;
}

export function windowMovementWarnings(first, second, exclude = []) {
  const warnings = [];
  for (const old of first.windowFrames) {
    if (exclude.includes(old.pid)) continue;
    const current = second.windowFrames.find(window => window.id === old.id && window.pid === old.pid);
    if (!current || ['x', 'y', 'width', 'height'].every(key => Math.abs(old.frame[key] - current.frame[key]) <= 1)) continue;
    warnings.push({ windowID: old.id, pid: old.pid, ownerName: current.ownerName ?? old.ownerName ?? `PID ${old.pid}`,
      before: old.frame, after: current.frame,
      beforeOnScreen: old.onScreen ?? null, afterOnScreen: current.onScreen ?? null,
      beforeSize: { width: old.frame.width, height: old.frame.height },
      reason: 'Window movement observed; cause cannot be attributed to the probe.' });
  }
  return warnings;
}
