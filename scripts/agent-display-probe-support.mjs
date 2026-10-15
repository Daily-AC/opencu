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

// Reviewer measurement, not a result of the current run. Keep it separate from
// heuristic detection below and do not rewrite the original evidence file.
export const measuredStageSideEffect = {
  source: '.cache/agent-display/run-4BTWD7/report.json', measuredLocalDate: '2026-10-16', phase: 'create',
  ownerName: 'Google Chrome', before: { x: 297, y: 208, width: 952, height: 727 },
  after: { x: 16, y: 646, width: 133, height: 141 },
  beforeOnScreen: null, afterOnScreen: null,
  reviewerObservation: 'Creating the display moved the person’s on-stage Chrome window into the Stage Manager strip.',
  limitation: 'Display-frame preservation does not establish preservation of the person’s stage. No supported no-stage-relayout option is known for CGVirtualDisplay.',
};

export function possibleStageRelayout(warning) {
  const { before, after } = warning;
  return before.width >= 400 && before.height >= 300 && after.width > 0 && after.height > 0
    && after.width <= before.width * 0.4 && after.height <= before.height * 0.4;
}
