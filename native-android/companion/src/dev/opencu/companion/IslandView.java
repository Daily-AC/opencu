package dev.opencu.companion;

import android.content.Context;
import android.graphics.*;
import android.graphics.drawable.Drawable;
import android.os.Handler;
import android.os.Looper;
import android.text.TextPaint;
import android.text.TextUtils;
import android.view.*;

/**
 * The status island: a black capsule at the top of the screen that shows what the agent does.
 * A tap opens it into a card with the app, the current step, Stop and (on the background screen)
 * Watch. It owns its overlay window and keeps that window just as large as what it draws, so the
 * rest of the screen keeps its touches.
 */
final class IslandView extends View implements Choreographer.FrameCallback {
  interface Listener {
    void onStop();

    void onTogglePreview();

    void onHidden();
  }

  static final int ACCENT = 0xFF30D158, RED = 0xFFFF453A, BUTTON = 0xFF2C2C2E, GRAY = 0xFF98989F;

  private final Listener listener;
  private final WindowManager wm;
  private final Handler main = new Handler(Looper.getMainLooper());
  private final float d, sp;
  private final int screenWidth, top;
  private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
  private final Paint stroke = new Paint(Paint.ANTI_ALIAS_FLAG);
  private final TextPaint compactText = new TextPaint(Paint.ANTI_ALIAS_FLAG);
  private final TextPaint titleText = new TextPaint(Paint.ANTI_ALIAS_FLAG);
  private final TextPaint smallText = new TextPaint(Paint.ANTI_ALIAS_FLAG);
  private final TextPaint actionText = new TextPaint(Paint.ANTI_ALIAS_FLAG);
  private final TextPaint buttonText = new TextPaint(Paint.ANTI_ALIAS_FLAG);
  private WindowManager.LayoutParams lp;
  private boolean attached, hiding, framePosted;
  private long lastFrameNanos;

  // Content.
  private Drawable icon;
  private String action = "", previous = "", title = "", where = "", step = "";
  private String state = "acting";
  private boolean background, previewOpen;

  // Motion: compact width, open (0 compact, 1 card), presence (0 gone, 1 shown), text crossfade.
  private final Spring width, open, presence, fade, press;
  private float spin;

  // Geometry, in pixels.
  private final float compactHeight, cardWidth, cardHeight, cardRadius, pad;
  private final RectF pill = new RectF(), stopButton = new RectF(), watchButton = new RectF();

  IslandView(Context context, Listener listener) {
    super(context);
    this.listener = listener;
    wm = context.getSystemService(WindowManager.class);
    d = getResources().getDisplayMetrics().density;
    sp = getResources().getDisplayMetrics().scaledDensity;
    Rect bounds = wm.getMaximumWindowMetrics().getBounds();
    screenWidth = Math.min(bounds.width(), bounds.height());
    int bar = getResources().getIdentifier("status_bar_height", "dimen", "android");
    int statusBar = bar > 0 ? getResources().getDimensionPixelSize(bar) : (int) (36 * d);
    top = statusBar + (int) (6 * d);
    compactHeight = 34 * d;
    cardWidth = Math.min(screenWidth - 20 * d, 400 * d);
    cardHeight = 172 * d;
    cardRadius = 30 * d;
    pad = 2 * d;
    width = new Spring(compactHeight, 0.42f, 0.78f, 0.3f);
    open = new Spring(0, 0.46f, 0.82f, 0.001f);
    presence = new Spring(0, 0.38f, 1f, 0.002f);
    fade = new Spring(1, 0.22f, 1f, 0.004f);
    press = new Spring(1, 0.2f, 0.9f, 0.001f);
    Typeface medium = Typeface.create("sans-serif-medium", Typeface.NORMAL);
    compactText.setTypeface(medium);
    compactText.setTextSize(13.5f * sp);
    compactText.setColor(Color.WHITE);
    titleText.setTypeface(Typeface.create("sans-serif", Typeface.BOLD));
    titleText.setTextSize(15.5f * sp);
    titleText.setColor(Color.WHITE);
    smallText.setTextSize(12.5f * sp);
    smallText.setColor(GRAY);
    actionText.setTypeface(medium);
    actionText.setTextSize(16.5f * sp);
    actionText.setColor(Color.WHITE);
    buttonText.setTypeface(medium);
    buttonText.setTextSize(15f * sp);
    buttonText.setTextAlign(Paint.Align.LEFT);
    stroke.setStyle(Paint.Style.STROKE);
    stroke.setStrokeCap(Paint.Cap.ROUND);
  }

  // ---- Content -------------------------------------------------------------------------------

  void setContent(
      Drawable icon, String action, String title, String where, String step, String state,
      boolean background) {
    boolean changed = !action.equals(this.action);
    // A stop ends the card's purpose: show it for a moment, then fold back into the capsule.
    if (state.equals("stopped") && !this.state.equals("stopped") && open.target > 0)
      main.postDelayed(this::close, 900);
    this.icon = icon;
    if (changed) {
      previous = this.action;
      this.action = action;
      fade.snap(0);
      fade.to(1);
    }
    this.title = title;
    this.where = where;
    this.step = step;
    this.state = state;
    boolean modeChanged = attached && background != this.background;
    this.background = background;
    if (!hiding) width.to(compactWidth());
    show();
    if (modeChanged) applyMode();
    kick();
  }

  /**
   * On the background screen the island takes taps: the person's screen is theirs and the card
   * offers Watch and Stop. When the agent works on this screen the island only shows what it
   * does: touches pass through to the app below (at 0.8 opacity, the most Android lets touches
   * pass through another app's window), so a tap never lands on the island as it changes size,
   * and touching the screen already pauses the agent.
   */
  private void applyMode() {
    if (background) {
      lp.flags &= ~WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE;
      lp.alpha = 1f;
    } else {
      lp.flags |= WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE;
      lp.alpha = 0.8f;
      open.to(0);
    }
    if (attached) wm.updateViewLayout(this, lp);
  }

  /** Puts this window back above the app's other overlay windows. */
  void raise() {
    if (!attached || hiding) return;
    wm.removeViewImmediate(this);
    wm.addView(this, lp);
  }

  void setPreviewOpen(boolean open) {
    previewOpen = open;
    kick();
  }

  boolean isOpen() {
    return open.target > 0;
  }

  private float textRoom() {
    return Math.min(screenWidth * 0.66f, 290 * d) - fixedCompact();
  }

  private float fixedCompact() {
    return 6 * d + 22 * d + 9 * d + 11 * d + 14 * d + 13 * d;
  }

  private float compactWidth() {
    float text = Math.min(compactText.measureText(action), textRoom());
    return fixedCompact() + text;
  }

  // ---- Window --------------------------------------------------------------------------------

  private void show() {
    hiding = false;
    if (!attached) {
      lp =
          new WindowManager.LayoutParams(
              1,
              1,
              WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
              WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                  | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
                  | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
                  | WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED
                  | WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH,
              PixelFormat.TRANSLUCENT);
      lp.gravity = Gravity.TOP | Gravity.CENTER_HORIZONTAL;
      lp.y = top;
      lp.layoutInDisplayCutoutMode =
          WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS;
      lp.setTitle("OpenCU status");
      lp.windowAnimations = 0; // the island animates itself
      width.snap(compactHeight);
      width.to(compactWidth());
      presence.snap(0);
      sizeWindow(true);
      if (!background) {
        lp.flags |= WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE;
        lp.alpha = 0.8f;
      }
      wm.addView(this, lp);
      attached = true;
    }
    presence.to(1);
    kick();
  }

  /** Shrinks to a dot and removes the window. */
  void hide() {
    if (!attached || hiding) return;
    hiding = true;
    open.to(0);
    width.to(compactHeight);
    presence.to(0);
    kick();
  }

  /**
   * Keeps the window around what is drawn: while anything grows, it is made large enough at once;
   * once at rest it fits exactly.
   */
  private void sizeWindow(boolean force) {
    boolean card = open.target > 0 || open.value > 0.001f;
    boolean resting = !width.moving() && !open.moving();
    float w, h;
    if (card) {
      w = cardWidth;
      h = cardHeight;
    } else {
      w = Math.max(width.value, width.target) + (resting ? 0 : 24 * d);
      h = compactHeight;
    }
    int ww = (int) Math.ceil(w + 2 * pad), wh = (int) Math.ceil(h + 2 * pad);
    boolean grow = ww > lp.width || wh > lp.height;
    if (force || grow || (resting && (ww != lp.width || wh != lp.height))) {
      lp.width = ww;
      lp.height = wh;
      if (attached) wm.updateViewLayout(this, lp);
    }
  }

  // ---- Animation -----------------------------------------------------------------------------

  private void kick() {
    if (!framePosted && attached) {
      framePosted = true;
      lastFrameNanos = 0;
      Choreographer.getInstance().postFrameCallback(this);
    }
  }

  @Override
  public void doFrame(long nanos) {
    framePosted = false;
    float dt = lastFrameNanos == 0 ? 1 / 60f : Math.min(0.05f, (nanos - lastFrameNanos) / 1e9f);
    lastFrameNanos = nanos;
    boolean moving = width.step(dt);
    moving |= open.step(dt);
    moving |= presence.step(dt);
    moving |= fade.step(dt);
    moving |= press.step(dt);
    boolean spinning = state.equals("acting") && !hiding;
    if (spinning) spin = (spin + dt * 400) % 360;
    if (hiding && !presence.moving() && presence.value == 0) {
      attached = false;
      hiding = false;
      wm.removeView(this);
      listener.onHidden();
      return;
    }
    sizeWindow(false);
    invalidate();
    if (moving || spinning) {
      framePosted = true;
      Choreographer.getInstance().postFrameCallback(this);
    } else {
      lastFrameNanos = 0;
    }
  }

  // ---- Drawing -------------------------------------------------------------------------------

  private static float clamp(float v) {
    return Math.max(0, Math.min(1, v));
  }

  private static float lerp(float a, float b, float t) {
    return a + (b - a) * t;
  }

  @Override
  protected void onDraw(Canvas canvas) {
    float t = clamp(open.value);
    float p = clamp(presence.value);
    float w = lerp(width.value, cardWidth, t), h = lerp(compactHeight, cardHeight, t);
    float r = lerp(compactHeight / 2, cardRadius, t);
    float cx = getWidth() / 2f;
    pill.set(cx - w / 2, pad, cx + w / 2, pad + h);
    canvas.save();
    float s = press.value * lerp(0.6f, 1f, p);
    canvas.scale(s, s, cx, pad);
    fill.setColor(Color.BLACK);
    fill.setAlpha((int) (255 * p));
    canvas.drawRoundRect(pill, r, r, fill);
    Path clip = new Path();
    clip.addRoundRect(pill, r, r, Path.Direction.CW);
    canvas.clipPath(clip);
    float compactAlpha = p * clamp(1 - t / 0.35f) * clamp((width.value - compactHeight) / (12 * d));
    float cardAlpha = p * clamp((t - 0.45f) / 0.55f);
    if (compactAlpha > 0) drawCompact(canvas, compactAlpha);
    if (cardAlpha > 0) {
      drawCard(canvas, cardAlpha);
    } else {
      stopButton.setEmpty();
      watchButton.setEmpty();
    }
    canvas.restore();
  }

  private void drawCompact(Canvas c, float alpha) {
    float cy = pill.centerY();
    float x = pill.left + 6 * d;
    drawIcon(c, x, cy - 11 * d, 22 * d, alpha);
    x += 22 * d + 9 * d;
    // Laid out for the width the capsule is heading to; the capsule's edge reveals it while it
    // grows, rather than the text being cut short for the in-between width.
    float room = textRoom();
    float baseline = cy - (compactText.descent() + compactText.ascent()) / 2;
    int color = state.equals("acting") ? Color.WHITE : 0xFFD1D1D6;
    drawFading(c, compactText, action, previous, x, baseline, room, color, alpha);
    drawIndicator(c, pill.right - 13 * d - 7 * d, cy, 7 * d, alpha);
  }

  private void drawFading(
      Canvas c, TextPaint paint, String now, String before, float x, float baseline, float room,
      int color, float alpha) {
    float f = clamp(fade.value);
    if (f < 1 && !before.isEmpty()) {
      paint.setColor(color);
      paint.setAlpha((int) (255 * alpha * (1 - f)));
      c.drawText(fit(paint, before, room), x, baseline - (1 - f) * 0 - f * 6 * d, paint);
    }
    paint.setColor(color);
    paint.setAlpha((int) (255 * alpha * f));
    c.drawText(fit(paint, now, room), x, baseline + (1 - f) * 6 * d, paint);
  }

  private static String fit(TextPaint paint, String text, float room) {
    return TextUtils.ellipsize(text, paint, Math.max(0, room), TextUtils.TruncateAt.END).toString();
  }

  private void drawIcon(Canvas c, float x, float y, float size, float alpha) {
    if (icon != null) {
      icon.setBounds((int) x, (int) y, (int) (x + size), (int) (y + size));
      icon.setAlpha((int) (255 * alpha));
      icon.draw(c);
      return;
    }
    fill.setColor(BUTTON);
    fill.setAlpha((int) (255 * alpha));
    c.drawCircle(x + size / 2, y + size / 2, size / 2, fill);
    drawV(c, x + size * 0.3f, y + size * 0.3f, size * 0.42f, Color.WHITE, alpha);
  }

  /** The OpenCU mark: a V-shaped pointer tip, as on the Mac. */
  static void drawV(Canvas c, float x, float y, float size, int color, float alpha) {
    Path v = new Path();
    v.moveTo(x, y);
    v.lineTo(x + size, y + 0.357f * size);
    v.lineTo(x + 0.411f * size, y + 0.411f * size);
    v.lineTo(x + 0.357f * size, y + size);
    v.close();
    Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
    p.setColor(color);
    p.setAlpha((int) (255 * alpha));
    c.drawPath(v, p);
  }

  private void drawIndicator(Canvas c, float cx, float cy, float radius, float alpha) {
    if (state.equals("stopped")) {
      fill.setColor(RED);
      fill.setAlpha((int) (255 * alpha));
      float s = radius * 0.62f;
      c.drawRoundRect(cx - s, cy - s, cx + s, cy + s, 2 * d, 2 * d, fill);
    } else if (state.equals("acting")) {
      stroke.setStrokeWidth(2.2f * d);
      stroke.setColor(Color.WHITE);
      stroke.setAlpha((int) (46 * alpha));
      c.drawCircle(cx, cy, radius - d, stroke);
      stroke.setColor(ACCENT);
      stroke.setAlpha((int) (255 * alpha));
      RectF ring = new RectF(cx - radius + d, cy - radius + d, cx + radius - d, cy + radius - d);
      c.drawArc(ring, spin, 110, false, stroke);
    } else {
      fill.setColor(ACCENT);
      fill.setAlpha((int) (150 * alpha));
      c.drawCircle(cx, cy, 3.5f * d, fill);
    }
  }

  private void drawCard(Canvas c, float alpha) {
    float l = pill.left + 18 * d, rgt = pill.right - 18 * d, y = pill.top + 18 * d;
    drawIcon(c, l, y, 40 * d, alpha);
    float tx = l + 40 * d + 12 * d, room = rgt - 30 * d - tx;
    titleText.setAlpha((int) (255 * alpha));
    c.drawText(fit(titleText, title, room), tx, y + 18 * d, titleText);
    smallText.setAlpha((int) (255 * alpha));
    c.drawText(fit(smallText, where, room), tx, y + 37 * d, smallText);
    drawIndicator(c, rgt - 8 * d, y + 13 * d, 8 * d, alpha);
    float ay = y + 40 * d + 14 * d + 17 * d;
    float stepWidth = step.isEmpty() ? 0 : smallText.measureText(step) + 10 * d;
    int color = state.equals("acting") ? Color.WHITE : 0xFFD1D1D6;
    drawFading(c, actionText, action, previous, l, ay, rgt - l - stepWidth, color, alpha);
    if (!step.isEmpty()) c.drawText(step, rgt - smallText.measureText(step), ay, smallText);
    float by = pill.bottom - 16 * d - 44 * d;
    if (state.equals("stopped")) {
      stopButton.setEmpty();
      watchButton.setEmpty();
      return;
    }
    if (background) {
      float mid = (l + rgt) / 2;
      watchButton.set(l, by, mid - 5 * d, by + 44 * d);
      stopButton.set(mid + 5 * d, by, rgt, by + 44 * d);
    } else {
      watchButton.setEmpty();
      stopButton.set(l, by, rgt, by + 44 * d);
    }
    if (!watchButton.isEmpty())
      drawButton(c, watchButton, previewOpen ? Words.hideWatch() : Words.watch(), Color.WHITE, false, alpha);
    drawButton(c, stopButton, Words.stop(), RED, true, alpha);
  }

  private void drawButton(Canvas c, RectF b, String label, int color, boolean stop, float alpha) {
    fill.setColor(BUTTON);
    fill.setAlpha((int) (255 * alpha));
    c.drawRoundRect(b, b.height() / 2, b.height() / 2, fill);
    float glyph = 12 * d, gap = 8 * d;
    float textWidth = buttonText.measureText(label);
    float x = b.centerX() - (glyph + gap + textWidth) / 2, cy = b.centerY();
    if (stop) {
      fill.setColor(color);
      fill.setAlpha((int) (255 * alpha));
      c.drawRoundRect(x + d, cy - glyph / 2 + d, x + glyph - d, cy + glyph / 2 - d, 2.5f * d, 2.5f * d, fill);
    } else {
      stroke.setStrokeWidth(1.6f * d);
      stroke.setColor(color);
      stroke.setAlpha((int) (255 * alpha));
      c.drawRoundRect(x, cy - glyph * 0.42f, x + glyph, cy + glyph * 0.42f, 2.5f * d, 2.5f * d, stroke);
      fill.setColor(color);
      fill.setAlpha((int) (255 * alpha));
      c.drawRoundRect(x + glyph * 0.48f, cy, x + glyph * 0.86f, cy + glyph * 0.28f, 1.2f * d, 1.2f * d, fill);
    }
    buttonText.setColor(color);
    buttonText.setAlpha((int) (255 * alpha));
    c.drawText(label, x + glyph + gap, cy - (buttonText.descent() + buttonText.ascent()) / 2, buttonText);
  }

  // ---- Touch ---------------------------------------------------------------------------------

  /**
   * Opens the card. It stays open until the person taps outside it or on it: a card that closed
   * by itself could let a tap meant for it land on the app below.
   */
  private void expand() {
    open.to(1);
    sizeWindow(false);
    kick();
  }

  void close() {
    if (open.target == 0) return;
    open.to(0);
    kick();
  }

  @Override
  public boolean onTouchEvent(MotionEvent e) {
    if (hiding) return true;
    switch (e.getActionMasked()) {
      case MotionEvent.ACTION_OUTSIDE:
        close();
        return true;
      case MotionEvent.ACTION_DOWN:
        if (pill.contains(e.getX(), e.getY())) {
          press.to(open.target > 0 ? 0.985f : 0.94f);
          kick();
        }
        return true;
      case MotionEvent.ACTION_CANCEL:
        press.to(1);
        kick();
        return true;
      case MotionEvent.ACTION_UP:
        press.to(1);
        kick();
        if (!pill.contains(e.getX(), e.getY())) return true;
        // Buttons answer only once the card is fully open, where the person can see them.
        boolean shown = open.target > 0 && open.value > 0.9f;
        if (open.target == 0) {
          expand();
        } else if (!shown) {
          return true;
        } else if (stopButton.contains(e.getX(), e.getY())) {
          listener.onStop();
        } else if (watchButton.contains(e.getX(), e.getY())) {
          listener.onTogglePreview();
          close();
        } else {
          close();
        }
        return true;
      default:
        return true;
    }
  }
}
