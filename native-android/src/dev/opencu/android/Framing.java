package dev.opencu.android;
import java.io.*;
import java.util.function.Consumer;
/** Newline framing is independent of read chunk sizes and never assumes a TTY. */
public final class Framing {
    public static void read(Reader reader,Consumer<String> receive) throws IOException {
        StringBuilder line=new StringBuilder();char[] chunk=new char[4096];int count;
        while((count=reader.read(chunk))!=-1)for(int i=0;i<count;i++) {
            char c=chunk[i];
            if(c=='\n'){receive.accept(line.toString());line.setLength(0);}
            else{if(line.length()>=4*1024*1024)throw new IOException("MCP request exceeds 4 MiB");line.append(c);}
        }
        // A partial final line is not a request. EOF is cancellation, never an implicit replay.
    }
}
