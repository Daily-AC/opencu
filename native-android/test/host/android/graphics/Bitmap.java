package android.graphics;

import java.io.IOException;
import java.io.OutputStream;
import java.nio.Buffer;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;

/**
 * Host stand-in: RGBA pixels and the few operations the screenshot path uses. Instead of a JPEG,
 * compress writes a line naming the image's size and source, so a check can tell which display
 * an image came from.
 */
public final class Bitmap {
  public enum Config {
    ARGB_8888
  }

  public enum CompressFormat {
    JPEG
  }

  private final int width, height;
  private final byte[] pixels;
  /** Where the pixels came from; scaled copies keep it. */
  public final String source;
  private boolean recycled;

  private Bitmap(int width, int height, String source) {
    this.width = width;
    this.height = height;
    this.pixels = new byte[width * height * 4];
    this.source = source;
  }

  /** A host-only image whose compressed form names {@code source}. */
  public static Bitmap of(int width, int height, String source) {
    return new Bitmap(width, height, source);
  }

  public static Bitmap createBitmap(int width, int height, Config config) {
    return new Bitmap(width, height, "pixels");
  }

  public static Bitmap createScaledBitmap(Bitmap src, int dstWidth, int dstHeight, boolean filter) {
    if (src.width == dstWidth && src.height == dstHeight) return src;
    return new Bitmap(dstWidth, dstHeight, src.source);
  }

  /** As on Android: raw bytes in pixel order; a short buffer is refused, a used one advances. */
  public void copyPixelsFromBuffer(Buffer buffer) {
    ByteBuffer bytes = (ByteBuffer) buffer;
    if (bytes.remaining() < pixels.length)
      throw new RuntimeException("Buffer not large enough for pixels");
    bytes.get(pixels);
  }

  public void setHasAlpha(boolean hasAlpha) {}

  public int getWidth() {
    return width;
  }

  public int getHeight() {
    return height;
  }

  /** The pixel as ARGB, from its RGBA bytes. */
  public int getPixel(int x, int y) {
    int i = (y * width + x) * 4;
    return (pixels[i + 3] & 0xff) << 24
        | (pixels[i] & 0xff) << 16
        | (pixels[i + 1] & 0xff) << 8
        | (pixels[i + 2] & 0xff);
  }

  public void recycle() {
    recycled = true;
  }

  public boolean isRecycled() {
    return recycled;
  }

  public boolean compress(CompressFormat format, int quality, OutputStream stream) {
    try {
      stream.write(
          ("host image " + width + "x" + height + " from " + source).getBytes(StandardCharsets.UTF_8));
      return true;
    } catch (IOException e) {
      return false;
    }
  }
}
