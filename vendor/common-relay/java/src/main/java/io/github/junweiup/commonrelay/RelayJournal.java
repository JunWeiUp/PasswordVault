package io.github.junweiup.commonrelay;

import org.json.*;
import java.io.*;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.function.LongSupplier;

/** One owner per directory; use an application-private directory. No credentials stored. */
public final class RelayJournal {
    private static final long RETENTION=7*86400;
    private final Path directory;
    private final LongSupplier clock;
    public RelayJournal(Path directory)throws Exception{this(directory,()->System.currentTimeMillis()/1000);}
    public RelayJournal(Path directory,LongSupplier clock)throws Exception{this.directory=directory;this.clock=clock;Files.createDirectories(directory);cleanup();}
    private static String digest(byte[] data)throws Exception{return Crypto.hex(MessageDigest.getInstance("SHA-256").digest(data));}
    private Path path(String scope,String kind,String sender,String id)throws Exception{return directory.resolve(digest(new JSONArray().put(scope).put(kind).put(sender).put(id).toString().getBytes(StandardCharsets.UTF_8))+".json");}
    private JSONObject read(Path path)throws Exception{return Files.exists(path)?new JSONObject(new String(Files.readAllBytes(path),StandardCharsets.UTF_8)):null;}
    private void write(Path path,JSONObject record)throws Exception{
        Path temp=Files.createTempFile(directory,"journal-",".tmp");
        try{
            try(FileOutputStream out=new FileOutputStream(temp.toFile())){out.write(record.toString().getBytes(StandardCharsets.UTF_8));out.getFD().sync();}
            Files.move(temp,path,StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING);
        }finally{Files.deleteIfExists(temp);}
    }
    public interface Seal {String seal(long expires)throws Exception;}
    synchronized JSONObject prepare(String scope,String id,String to,byte[] data,long ttl,Seal seal)throws Exception{
        if(ttl<1||ttl>86400)throw new IllegalArgumentException("TTL");
        Path path=path(scope,"out","",id);long now=clock.getAsLong();String digest=digest(data);JSONObject row=read(path);
        if(row!=null){
            if(!row.getString("recipient").equals(to)||!row.getString("digest").equals(digest))throw new IOException("Message ID content conflict");
            if(row.getString("status").equals("received"))return row;
            if(!row.getString("status").equals("pending")||row.getLong("expires")<=now)throw new IOException("Message expired");
            return row;
        }
        long expires=now+ttl;
        row=new JSONObject().put("recipient",to).put("digest",digest).put("body",seal.seal(expires)).put("expires",expires).put("purge",expires+RETENTION).put("status","pending");write(path,row);return row;
    }
    synchronized void complete(String scope,String id)throws Exception{Path path=path(scope,"out","",id);JSONObject row=read(path);if(row!=null){row.remove("body");row.put("status","received").put("purge",clock.getAsLong()+RETENTION);write(path,row);}}
    synchronized boolean contains(String scope,String sender,String id)throws Exception{JSONObject row=read(path(scope,"in",sender,id));return row!=null&&row.getLong("purge")>clock.getAsLong();}
    synchronized void acknowledge(String scope,String sender,String id)throws Exception{Path path=path(scope,"in",sender,id);JSONObject row=read(path);if(row==null||row.getLong("purge")<=clock.getAsLong())write(path,new JSONObject().put("purge",clock.getAsLong()+RETENTION));}
    public synchronized void cleanup()throws Exception{
        long now=clock.getAsLong();int changed=0;
        try(DirectoryStream<Path> paths=Files.newDirectoryStream(directory,"*.json")){
            for(Path path:paths){
                if(changed>=256)break;
                if(!path.getFileName().toString().matches("[a-f0-9]{64}\\.json"))continue;
                JSONObject row=read(path);
                if(row.getLong("purge")<=now){Files.delete(path);changed++;}
                else if(row.optString("status").equals("pending")&&row.getLong("expires")<=now){row.remove("body");row.put("status","expired");write(path,row);changed++;}
            }
        }
    }
}
