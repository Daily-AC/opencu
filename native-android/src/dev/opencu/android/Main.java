package dev.opencu.android;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;

public final class Main {
    private static final PrintWriter output=new PrintWriter(new OutputStreamWriter(System.out,StandardCharsets.UTF_8),true);
    private static synchronized void emit(Map<String,Object> value) { if(value!=null)output.println(Json.write(value)); }
    public static void main(String[] args) {
        AndroidEngine engine=null;
        try {
            String mode=args.length==0?"mcp":args[0];
            if(args.length>1||(!mode.equals("mcp")&&!mode.equals("doctor")))throw new IllegalArgumentException("Usage: dev.opencu.android.Main [mcp|doctor]");
            engine=new AndroidEngine(Main::emit);final AndroidEngine active=engine;
            Runtime.getRuntime().addShutdownHook(new Thread(active::close));
            if(mode.equals("doctor")) { emit(engine.doctor());engine.close();System.exit(0); }
            Protocol protocol=new Protocol(engine,BuildInfo.VERSION);
            ThreadPoolExecutor worker=new ThreadPoolExecutor(1,1,0,TimeUnit.MILLISECONDS,new ArrayBlockingQueue<>(32),r->{Thread t=new Thread(r,"opencu-mcp");t.setDaemon(true);return t;});
            // The reader remains live while a call waits: EOF cancels even a long in-flight batch.
            Reader reader=new InputStreamReader(System.in,StandardCharsets.UTF_8);
            Framing.read(reader,request->worker.execute(()->emit(protocol.handle(request))));
            engine.close();worker.shutdownNow();System.exit(0);
        }catch(Throwable error) {
            System.err.println("OpenCU Android: "+error);
            if(args.length==1&&args[0].equals("doctor"))emit(Json.obj("version",BuildInfo.VERSION,"sdk",android.os.Build.VERSION.SDK_INT,"uid",android.os.Process.myUid(),"uiAutomationConnected",false,"error",error.toString()));
            if(engine!=null)engine.close();System.exit(1);
        }
    }
}
