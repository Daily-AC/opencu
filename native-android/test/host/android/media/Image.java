package android.media;

import java.nio.ByteBuffer;

/** Host stand-in: the frame accessors the agent display's capture reads, open to test frames. */
public abstract class Image implements AutoCloseable {
  protected Image() {}

  public abstract int getFormat();

  public abstract int getWidth();

  public abstract int getHeight();

  public abstract Plane[] getPlanes();

  @Override
  public abstract void close();

  public abstract static class Plane {
    protected Plane() {}

    public abstract int getRowStride();

    public abstract int getPixelStride();

    public abstract ByteBuffer getBuffer();
  }
}
