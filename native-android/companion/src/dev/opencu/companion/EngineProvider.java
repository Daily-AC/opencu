package dev.opencu.companion;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.net.Uri;
import android.os.Binder;
import android.os.Bundle;
import android.os.IBinder;

/**
 * The engine's way in. The engine runs as Android shell and calls {@code attach} with its Binder
 * once per connection; the answer is this app's Binder for status. Any other caller is refused.
 */
public final class EngineProvider extends ContentProvider {
  @Override
  public boolean onCreate() {
    return true;
  }

  @Override
  public Bundle call(String method, String arg, Bundle extras) {
    if (Binder.getCallingUid() != Island.SHELL_UID)
      throw new SecurityException("Only the OpenCU engine may attach");
    if (!"attach".equals(method) || extras == null) return null;
    IBinder engine = extras.getBinder("engine");
    if (engine == null) return null;
    Bundle reply = new Bundle();
    reply.putBinder("peer", Island.get(getContext()).attach(engine));
    return reply;
  }

  @Override
  public Cursor query(Uri uri, String[] projection, String selection, String[] args, String sort) {
    return null;
  }

  @Override
  public String getType(Uri uri) {
    return null;
  }

  @Override
  public Uri insert(Uri uri, ContentValues values) {
    return null;
  }

  @Override
  public int delete(Uri uri, String selection, String[] args) {
    return 0;
  }

  @Override
  public int update(Uri uri, ContentValues values, String selection, String[] args) {
    return 0;
  }
}
