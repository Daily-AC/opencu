package dev.opencu.companion;

import android.content.Context;
import android.graphics.*;
import android.os.Handler;
import android.os.Looper;
import android.text.TextPaint;
import android.view.*;
import android.widget.FrameLayout;

/**
 * A floating, read-only live view of the agent's background screen. The engine mirrors its agent
 * display into this window's surface; touches here never reach that display. Drag it anywhere; it
 * settles at the nearer side. A tap shows Close and Stop.
 */
final class PreviewWindow implements TextureView.SurfaceTextureListener, Choreographer.FrameCallback {
  interface Listener {
    /** Attaches (a surface) or detaches (null) the mirror; returns whether it is shown. */
    boolean attach(Surface surface, int width, int height);

    void onStop();

    void onClosed();
  }

  private final Context context;
  private final Listener listener;
  private final WindowManager wm;
  private final Handler main = new Handler(Looper.getMainLooper());
  private final float d;
  private final int screenWidth, screenHeight, margin, cardWidth, cardHeight, edge, topLimit;
  private final FrameLayout root;
  private final FrameLayout card;
  private final TextureView texture;
  private final Controls controls;
  private WindowManager.LayoutParams lp;
  private Surface surface;
  private boolean attached, closing, framesSeen, unavailable;
  private final Spring x, y;
  private boolean framePosted;
  private long lastFrameNanos;
  private final Runnable hideControls = this::hideControlsNow;
  /** Attach and detach reach the engine in the order they were asked. */
  private final java.util.concurrent.ExecutorService calls =
      java.util.concurrent.Executors.newSingleThreadExecutor();

  PreviewWindow(Context context, Listener listener) {
    this.context = context;
    this.listener = listener;
    wm = context.getSystemService(WindowManager.class);
    d = context.getResources().getDisplayMetrics().density;
    Rect bounds = wm.getMaximumWindowMetrics().getBounds();
    screenWidth = bounds.width();
    screenHeight = bounds.height();
    int naturalW = Math.min(screenWidth, screenHeight), naturalH = Math.max(screenWidth, screenHeight);
    margin = (int) (16 * d);
    cardWidth = (int) (naturalW * 0.36f);
    cardHeight = Math.round(cardWidth * (naturalH / (float) naturalW));
    edge = (int) (10 * d);
    int bar = context.getResources().getIdentifier("status_bar_height", "dimen", "android");
    topLimit = (bar > 0 ? context.getResources().getDimensionPixelSize(bar) : (int) (36 * d)) + (int) (48 * d);
    x = new Spring(0, 0.5f, 0.86f, 0.5f);
    y = new Spring(0, 0.5f, 0.86f, 0.5f);

    root = new FrameLayout(context);
    root.setClipChildren(false);
    root.setClipToPadding(false);
    root.setPadding(margin, margin, margin, margin);
    card = new FrameLayout(context);
    card.setBackgroundColor(Color.BLACK);
    card.setOutlineProvider(
        new ViewOutlineProvider() {
          @Override
          public void getOutline(View view, Outline outline) {
            outline.setRoundRect(0, 0, view.getWidth(), view.getHeight(), 20 * d);
          }
        });
    card.setClipToOutline(true);
    card.setElevation(12 * d);
    texture = new TextureView(context);
    texture.setOpaque(false);
    texture.setSurfaceTextureListener(this);
    card.addView(texture, new FrameLayout.LayoutParams(cardWidth, cardHeight));
    controls = new Controls(context);
    card.addView(controls, new FrameLayout.LayoutParams(cardWidth, cardHeight));
    root.addView(card, new FrameLayout.LayoutParams(cardWidth, cardHeight));
    root.setOnTouchListener(new Drag());
  }

  private void hideControlsNow() {
    controls.show(false);
  }

  boolean isShown() {
    return attached && !closing;
  }

  void show() {
    if (attached) {
      if (closing) {
        closing = false;
        root.animate().cancel();
        appear();
      }
      return;
    }
    lp =
        new WindowManager.LayoutParams(
            cardWidth + 2 * margin,
            cardHeight + 2 * margin,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
                | WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
            PixelFormat.TRANSLUCENT);
    lp.gravity = Gravity.TOP | Gravity.LEFT;
    lp.setTitle("OpenCU preview");
    lp.windowAnimations = 0; // the window animates itself
    int startX = screenWidth - cardWidth - margin - edge;
    // Below where the island's card opens, so the card does not cover it.
    int startY = topLimit + (int) (150 * d);
    x.snap(startX);
    y.snap(startY);
    lp.x = startX;
    lp.y = startY;
    framesSeen = false;
    unavailable = false;
    wm.addView(root, lp);
    attached = true;
    appear();
  }

  private void appear() {
    root.setPivotX(root.getWidth() > 0 ? root.getWidth() : cardWidth);
    root.setPivotY(0);
    root.setAlpha(0);
    root.setScaleX(0.86f);
    root.setScaleY(0.86f);
    root.animate()
        .alpha(1)
        .scaleX(1)
        .scaleY(1)
        .setDuration(320)
        .setInterpolator(new android.view.animation.PathInterpolator(0.2f, 0, 0, 1))
        .withEndAction(null)
        .start();
  }

  void close() {
    if (!attached || closing) return;
    closing = true;
    main.removeCallbacks(hideControls);
    root.animate()
        .alpha(0)
        .scaleX(0.9f)
        .scaleY(0.9f)
        .setDuration(220)
        .setInterpolator(new android.view.animation.PathInterpolator(0.4f, 0, 1, 1))
        .withEndAction(
            () -> {
              if (!closing) return;
              closing = false;
              attached = false;
              detachSurface();
              wm.removeView(root);
              listener.onClosed();
            })
        .start();
  }

  // ---- Surface -------------------------------------------------------------------------------

  @Override
  public void onSurfaceTextureAvailable(SurfaceTexture st, int width, int height) {
    st.setDefaultBufferSize(width, height);
    surface = new Surface(st);
    final Surface s = surface;
    calls.execute(
        () -> {
          boolean shown = listener.attach(s, width, height);
          main.post(
              () -> {
                unavailable = !shown;
                controls.invalidate();
              });
        });
  }

  @Override
  public void onSurfaceTextureSizeChanged(SurfaceTexture st, int width, int height) {}

  @Override
  public boolean onSurfaceTextureDestroyed(SurfaceTexture st) {
    detachSurface();
    return true;
  }

  @Override
  public void onSurfaceTextureUpdated(SurfaceTexture st) {
    if (!framesSeen) {
      framesSeen = true;
      controls.invalidate();
    }
  }

  private void detachSurface() {
    if (surface == null) return;
    final Surface s = surface;
    surface = null;
    calls.execute(
        () -> {
          listener.attach(null, 0, 0);
          s.release();
        });
  }

  // ---- Movement ------------------------------------------------------------------------------

  private void settle() {
    int w = cardWidth + 2 * margin;
    float cx = x.value + w / 2f;
    x.to(cx < screenWidth / 2f ? edge - margin : screenWidth - w + margin - edge);
    float maxY = screenHeight - cardHeight - margin - 40 * d;
    y.to(Math.max(topLimit - margin, Math.min(maxY, y.value)));
    kick();
  }

  private void kick() {
    if (!framePosted) {
      framePosted = true;
      lastFrameNanos = 0;
      Choreographer.getInstance().postFrameCallback(this);
    }
  }

  @Override
  public void doFrame(long nanos) {
    framePosted = false;
    if (!attached) return;
    float dt = lastFrameNanos == 0 ? 1 / 60f : Math.min(0.05f, (nanos - lastFrameNanos) / 1e9f);
    lastFrameNanos = nanos;
    boolean moving = x.step(dt) | y.step(dt);
    place();
    if (moving) kick();
  }

  private void place() {
    int nx = Math.round(x.value), ny = Math.round(y.value);
    if (nx != lp.x || ny != lp.y) {
      lp.x = nx;
      lp.y = ny;
      wm.updateViewLayout(root, lp);
    }
  }

  private final class Drag implements View.OnTouchListener {
    private float downX, downY, startX, startY;
    private boolean dragging;
    private final int slop = ViewConfiguration.get(context).getScaledTouchSlop();

    @Override
    public boolean onTouch(View v, MotionEvent e) {
      switch (e.getActionMasked()) {
        case MotionEvent.ACTION_DOWN:
          downX = e.getRawX();
          downY = e.getRawY();
          startX = x.value;
          startY = y.value;
          dragging = false;
          return true;
        case MotionEvent.ACTION_MOVE:
          float dx = e.getRawX() - downX, dy = e.getRawY() - downY;
          if (!dragging && Math.hypot(dx, dy) > slop) dragging = true;
          if (dragging) {
            x.snap(startX + dx);
            y.snap(startY + dy);
            place();
          }
          return true;
        case MotionEvent.ACTION_UP:
          if (dragging) {
            settle();
          } else {
            float cx = e.getX() - margin, cy = e.getY() - margin;
            if (controls.shown && controls.close.contains(cx, cy)) close();
            else if (controls.shown && controls.stop.contains(cx, cy)) listener.onStop();
            else controls.show(!controls.shown);
          }
          return true;
        case MotionEvent.ACTION_CANCEL:
          if (dragging) settle();
          return true;
        default:
          return true;
      }
    }
  }

  // ---- Controls ------------------------------------------------------------------------------

  /** Close and Stop over a soft top shade; a quiet line while no frame has come. */
  private final class Controls extends View {
    boolean shown;
    final RectF close = new RectF(), stop = new RectF();
    private float alpha;
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final TextPaint text = new TextPaint(Paint.ANTI_ALIAS_FLAG);

    Controls(Context c) {
      super(c);
      text.setColor(0xFFD1D1D6);
      text.setTextSize(12 * c.getResources().getDisplayMetrics().scaledDensity);
      text.setTextAlign(Paint.Align.CENTER);
    }

    void show(boolean on) {
      shown = on;
      main.removeCallbacks(hideControls);
      if (on) main.postDelayed(hideControls, 3000);
      animate().cancel();
      ValueAnimatorHolder.run(this, alpha, on ? 1 : 0);
    }

    void setFade(float a) {
      alpha = a;
      invalidate();
    }

    @Override
    protected void onDraw(Canvas c) {
      float w = getWidth(), h = getHeight();
      if (!framesSeen || unavailable) {
        String line = unavailable ? Words.previewUnavailable() : Words.noFrames();
        c.drawText(line, w / 2, h / 2, text);
      }
      if (alpha <= 0) return;
      paint.setShader(new LinearGradient(0, 0, 0, 64 * d, 0x99000000, 0x00000000, Shader.TileMode.CLAMP));
      paint.setAlpha((int) (255 * alpha));
      c.drawRect(0, 0, w, 64 * d, paint);
      paint.setShader(null);
      float r = 15 * d, pad = 10 * d;
      close.set(pad, pad, pad + 2 * r, pad + 2 * r);
      stop.set(w - pad - 2 * r, pad, w - pad, pad + 2 * r);
      paint.setColor(0xCC2C2C2E);
      paint.setAlpha((int) (0xCC * alpha));
      c.drawCircle(close.centerX(), close.centerY(), r, paint);
      c.drawCircle(stop.centerX(), stop.centerY(), r, paint);
      paint.setStyle(Paint.Style.STROKE);
      paint.setStrokeWidth(1.8f * d);
      paint.setStrokeCap(Paint.Cap.ROUND);
      paint.setColor(Color.WHITE);
      paint.setAlpha((int) (255 * alpha));
      float k = 4.5f * d;
      c.drawLine(close.centerX() - k, close.centerY() - k, close.centerX() + k, close.centerY() + k, paint);
      c.drawLine(close.centerX() + k, close.centerY() - k, close.centerX() - k, close.centerY() + k, paint);
      paint.setStyle(Paint.Style.FILL);
      paint.setColor(IslandView.RED);
      paint.setAlpha((int) (255 * alpha));
      float s = 5 * d;
      c.drawRoundRect(stop.centerX() - s, stop.centerY() - s, stop.centerX() + s, stop.centerY() + s, 2 * d, 2 * d, paint);
    }
  }

  /** Fades the controls with an eased animator. */
  private static final class ValueAnimatorHolder {
    static void run(Controls view, float from, float to) {
      android.animation.ValueAnimator a = android.animation.ValueAnimator.ofFloat(from, to);
      a.setDuration(200);
      a.setInterpolator(new android.view.animation.PathInterpolator(0.2f, 0, 0, 1));
      a.addUpdateListener(v -> view.setFade((Float) v.getAnimatedValue()));
      a.start();
    }
  }
}
