package dev.opencu.android.fixture;
import android.app.Activity;
import android.os.Bundle;
import android.view.WindowManager;
import android.widget.TextView;
public final class SecondActivity extends Activity {
    public void onCreate(Bundle saved){super.onCreate(saved);getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON|WindowManager.LayoutParams.FLAG_FULLSCREEN);TextView text=new TextView(this);text.setText("Fixture second activity");text.setTextSize(24);setContentView(text);Truth.put(this,"screen","second");}
}
