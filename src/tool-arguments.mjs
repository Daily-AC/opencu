// Some models fill every optional schema field with a placeholder (x: 0, y: 0, key: "NONE").
// Drop those placeholders so an indexed click is not mistaken for a coordinate click.
const emptyKeys = new Set(['', 'none', 'null', 'undefined']);

export function normalizeAction(action) {
  const normalized = { ...action };
  if (['click', 'scroll'].includes(normalized.method) && normalized.element_index !== undefined
    && normalized.x === 0 && normalized.y === 0) {
    delete normalized.x;
    delete normalized.y;
  }
  // Element indexes start at 1, so 0 or a negative index next to coordinates is a placeholder.
  if (['click', 'scroll'].includes(normalized.method) && Number.isInteger(normalized.element_index) && normalized.element_index < 1
    && normalized.x !== undefined && normalized.y !== undefined) {
    delete normalized.element_index;
  }
  if (typeof normalized.key === 'string' && normalized.method === 'click' && emptyKeys.has(normalized.key.trim().toLowerCase())) {
    delete normalized.key;
  }
  return normalized;
}

export function checkTarget(action) {
  if (!['click', 'scroll'].includes(action.method)) return;
  const hasPoint = action.x !== undefined || action.y !== undefined;
  if (action.element_index !== undefined && hasPoint) {
    throw new Error(`Received element_index ${action.element_index} together with x=${action.x}, y=${action.y}. To use the element, omit x and y; to use screenshot coordinates, omit element_index. No actions were sent.`);
  }
  if (action.element_index === undefined && (action.x === undefined || action.y === undefined)) {
    throw new Error('Provide element_index or both x and y from the latest app state. No actions were sent.');
  }
}

export function normalizeArguments(name, args) {
  if (name === 'run_actions') {
    const actions = (args.actions ?? []).map(normalizeAction);
    actions.forEach(checkTarget);
    return { ...args, actions };
  }
  const { method, ...rest } = normalizeAction({ method: name, ...args });
  checkTarget({ method, ...rest });
  return rest;
}
