// The native API interprets points in its last observed app-window screenshot.
// Keep that contract explicit; never refresh or replay a coordinate action.
const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

// The engine returns PNG window images; any other header fails closed.
export function imageSize(bytes) {
  if (bytes.length < 24 || !bytes.subarray(0, 8).equals(PNG_SIGNATURE)) return;
  const width = bytes.readUInt32BE(16);
  const height = bytes.readUInt32BE(20);
  return width && height ? { width, height } : undefined;
}

function points(method, args) {
  if (method === 'drag') return [[args.from_x, args.from_y], [args.to_x, args.to_y]];
  if (['click', 'scroll'].includes(method) && args.element_index === undefined) return [[args.x, args.y]];
  return [];
}

export class CoordinateState {
  #snapshot;
  #reason = 'No screenshot has been returned in this connection.';

  before(method, args) {
    const actions = method === 'run_actions' ? args.actions : [{ method, ...args }];
    for (const [index, action] of actions.entries()) {
      const coordinates = points(action.method, action);
      if (!coordinates.length) continue;
      if (index > 0) {
        throw Object.assign(new Error(`Action ${index + 1} uses coordinates after an earlier UI action. No actions were sent. End this batch before that action, call get_app_state with includeScreenshot: true, and inspect the new screenshot before continuing.`), { code: 'SCREENSHOT_REQUIRED' });
      }
      const snapshot = this.#snapshot;
      if (!snapshot || !snapshot.apps.includes(args.app)) {
        const reason = snapshot ? 'The last screenshot belongs to a different app identifier.' : this.#reason;
        throw Object.assign(new Error(`Coordinate input requires a fresh screenshot. ${reason} No coordinate action was sent. Call get_app_state with app ${JSON.stringify(args.app)} and includeScreenshot: true, inspect the returned window, then choose coordinates from that image.`), { code: 'SCREENSHOT_REQUIRED' });
      }
      for (const [x, y] of coordinates) {
        if (!Number.isFinite(x) || !Number.isFinite(y) || x < 0 || y < 0 || x >= snapshot.width || y >= snapshot.height) {
          throw new Error(`Coordinate (${x}, ${y}) is outside the last screenshot (${snapshot.width} x ${snapshot.height} pixels${snapshot.window ? `, window ${JSON.stringify(snapshot.window)}` : ''}). Valid ranges: 0 <= x < ${snapshot.width}, 0 <= y < ${snapshot.height}. No input was sent. Use coordinates from that image, or request a new screenshot.`);
        }
      }
    }
    if (method !== 'list_apps') {
      this.#snapshot = undefined;
      this.#reason = method === 'get_app_state'
        ? 'The latest state read did not return a usable screenshot.'
        : 'A UI action was requested after the last screenshot; its window or contents may have changed.';
    }
  }

  after(method, args, result) {
    if (!['get_app_state', 'activate_app', 'run_actions', 'click', 'drag', 'scroll'].includes(method) || result.isError) return result;
    const image = result.content?.find(item => item.type === 'image' && typeof item.data === 'string');
    const size = image && imageSize(Buffer.from(image.data, 'base64'));
    if (!size) return result;
    const text = result.content.filter(item => item.type === 'text').map(item => item.text).join('\n');
    const window = text.match(/\bWindow: "(.*?)"/)?.[1];
    const canonical = result._meta?.['opencu/app']?.id;
    this.#snapshot = { ...size, window, apps: [args.app, canonical].filter(value => typeof value === 'string' && value) };
    result.content.push({ type: 'text', text: `Screenshot coordinates: ${size.width} x ${size.height} pixels${window ? `, window ${JSON.stringify(window)}` : ''}. Origin is the top-left of this app-window image. Use 0 <= x < ${size.width} and 0 <= y < ${size.height}. This image is current after the completed call. After further input, use that action's returned image or request a new screenshot before choosing coordinates.` });
    return result;
  }
}
